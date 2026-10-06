defmodule MealPlannerApi.ShoppingCheckout do
  @moduledoc """
  Orchestrates shopping list interactions and checkout to inventory.
  """

  alias MealPlannerApi.Inventory, as: DomainInventory
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Persistence.Shopping

  @default_days_window 7

  @spec list_shopping_view(map(), map()) :: {:ok, map()} | {:error, term()}
  def list_shopping_view(current_user, params) when is_map(params) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, from_date, to_date} <- parse_date_range(params),
         :ok <- prune_past_unpurchased(ids.account_id),
         {:ok, _created} <- sync_from_planning(ids.account_id, current_user, from_date, to_date) do
      items = Shopping.list_pending_items_with_context(ids.account_id, from_date, to_date)
      categories = parse_categories(params)
      optimize_prices = parse_bool(Map.get(params, "optimize_prices"))

      filtered = filter_by_categories(items, categories)
      grouped_items = group_by_ingredient(filtered)
      grouped_with_prices = maybe_attach_price_options(grouped_items, optimize_prices)

      {:ok,
       %{
         date_from: Date.to_iso8601(from_date),
         date_to: Date.to_iso8601(to_date),
         recovery_mode: Enum.any?(filtered, &(&1.status == :in_cart)),
         pending_deliveries_count:
           length(Shopping.list_pending_delivery_sessions(ids.account_id)),
         optimize_prices: optimize_prices,
         grouped_by_category: grouped_by_category(grouped_with_prices),
         items: grouped_with_prices,
         totals: %{
           grouped_rows: length(grouped_with_prices),
           pending_count: Enum.count(filtered, &(&1.status == :pending)),
           in_cart_count: Enum.count(filtered, &(&1.status == :in_cart))
         }
       }}
    end
  end

  @spec mark_cart(map(), binary(), boolean(), map()) :: {:ok, map()} | {:error, term()}
  def mark_cart(current_user, ingredient_id, in_cart, params \\ %{})
      when is_binary(ingredient_id) and is_boolean(in_cart) and is_map(params) do
    with {:ok, from_date, to_date} <- parse_date_range(params) do
      if in_cart do
        MealPlannerApi.Cart.reserve_ingredient(current_user, ingredient_id, from_date, to_date)
      else
        MealPlannerApi.Cart.remove(current_user, params["session_id"], params["items"])
      end
    end
  end

  @spec assign_supermarket(map(), binary(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def assign_supermarket(current_user, ingredient_id, supermarket_id, params \\ %{})
      when is_binary(ingredient_id) and is_binary(supermarket_id) and is_map(params) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, from_date, to_date} <- parse_date_range(params),
         supermarket when not is_nil(supermarket) <- Shopping.get_supermarket(supermarket_id) do
      {updated, _} =
        Shopping.update_open_items_for_ingredient(
          ids.account_id,
          ingredient_id,
          %{assigned_supermarket_id: supermarket_id},
          from_date,
          to_date
        )

      {:ok,
       %{
         ingredient_id: ingredient_id,
         assigned_supermarket_id: supermarket.id,
         assigned_supermarket_name: supermarket.name,
         updated_rows: updated
       }}
    else
      nil -> {:error, :supermarket_not_found}
      {:error, _} = error -> error
    end
  end

  @spec confirm_checkout(map(), map()) :: {:ok, map()} | {:error, term()}
  def confirm_checkout(current_user, payload) when is_map(payload) do
    MealPlannerApi.Cart.purchase(current_user, payload["session_id"], payload)
  end

  @spec confirm_delivery_arrived(map(), binary()) :: {:ok, map()} | {:error, term()}
  def confirm_delivery_arrived(current_user, checkout_session_id)
      when is_binary(checkout_session_id) do
    MealPlannerApi.Cart.delivery(current_user, checkout_session_id)
  end

  defp parse_date_range(params) do
    today = Date.utc_today()

    with {:ok, from_date} <- parse_date(Map.get(params, "start_date"), today),
         {:ok, to_date} <-
           parse_date(Map.get(params, "end_date"), Date.add(from_date, @default_days_window - 1)),
         :ok <- ensure_date_order(from_date, to_date) do
      {:ok, from_date, to_date}
    end
  end

  defp parse_date(nil, default), do: {:ok, default}

  defp parse_date(value, _default) when is_binary(value) do
    Date.from_iso8601(value)
  end

  defp parse_date(_, _default), do: {:error, :invalid_date_range}

  defp ensure_date_order(from_date, to_date) do
    if Date.compare(from_date, to_date) in [:lt, :eq],
      do: :ok,
      else: {:error, :invalid_date_range}
  end

  defp parse_categories(params) do
    case Map.get(params, "categories") do
      nil ->
        :all

      "" ->
        :all

      raw when is_binary(raw) ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_existing_atom/1)

      _ ->
        :all
    end
  rescue
    ArgumentError -> :all
  end

  defp filter_by_categories(items, :all), do: items

  defp filter_by_categories(items, categories) when is_list(categories) do
    Enum.filter(items, fn item -> item.ingredient.category in categories end)
  end

  defp parse_bool("true"), do: true
  defp parse_bool(true), do: true
  defp parse_bool(_), do: false

  defp prune_past_unpurchased(account_id) do
    _ = Shopping.archive_outdated_unpurchased(account_id, Date.utc_today())
    :ok
  end

  defp sync_from_planning(account_id, current_user, from_date, to_date) do
    existing_open_items = Shopping.list_pending_items(account_id, from_date, to_date)

    if existing_open_items != [] do
      {:ok, 0}
    else
      available_pool =
        current_user
        |> DomainInventory.available_for(%{})
        |> build_available_pool()

      meals =
        Planning.list_uncooked_scheduled_meals_with_recipe_ingredients(
          account_id,
          from_date,
          to_date
        )

      {created, _remaining_pool} =
        Enum.reduce(meals, {0, available_pool}, fn meal, {acc, pool} ->
          recipe = MealPlannerApi.Services.RecipeVersions.recipe_for_meal(meal)
          recipe_ingredients = (recipe && recipe.recipe_ingredients) || []

          Enum.reduce(recipe_ingredients, {acc, pool}, fn ri, {local_acc, local_pool} ->
            key = {ri.ingredient_id, ri.unit}
            available = Map.get(local_pool, key, 0)
            needed = ri.quantity_milli
            consumed = min(available, needed)
            missing = needed - consumed
            updated_pool = Map.put(local_pool, key, max(available - consumed, 0))

            if missing > 0 do
              {:ok, _item} =
                Shopping.create_shopping_item(%{
                  account_id: account_id,
                  scheduled_meal_id: meal.id,
                  planned_date: meal.date,
                  ingredient_id: ri.ingredient_id,
                  quantity_milli: missing,
                  unit: ri.unit,
                  status: :pending
                })

              {local_acc + 1, updated_pool}
            else
              {local_acc, updated_pool}
            end
          end)
        end)

      {:ok, created}
    end
  end

  defp build_available_pool(items) when is_list(items) do
    Enum.reduce(items, %{}, fn item, acc ->
      key = {item.ingredient_id, item.unit}
      Map.update(acc, key, item.quantity_milli, &(&1 + item.quantity_milli))
    end)
  end

  defp maybe_attach_price_options(grouped_items, false), do: grouped_items

  defp maybe_attach_price_options(grouped_items, true) do
    ingredient_ids = grouped_items |> Enum.map(& &1.ingredient_id) |> Enum.uniq()

    options_by_ingredient =
      Shopping.latest_catalog_for_ingredients(ingredient_ids)
      |> Enum.group_by(& &1.ingredient_id)

    Enum.map(grouped_items, fn item ->
      options =
        options_by_ingredient
        |> Map.get(item.ingredient_id, [])
        |> Enum.sort_by(& &1.price_cents_ars)
        |> Enum.map(fn option ->
          %{
            supermarket_id: option.supermarket_id,
            supermarket_name: option.supermarket_name,
            price_cents_ars: option.price_cents_ars,
            unit: option.unit,
            price_date: Date.to_iso8601(option.price_date)
          }
        end)

      Map.put(item, :price_options, options)
    end)
  end

  defp group_by_ingredient(items) do
    items
    |> Enum.group_by(fn item -> {item.ingredient_id, item.unit} end)
    |> Enum.map(fn {{ingredient_id, unit}, rows} ->
      first = hd(rows)
      total_qty = Enum.reduce(rows, 0, &(&1.quantity_milli + &2))
      in_cart = Enum.count(rows, &(&1.status == :in_cart))
      assigned_ids = rows |> Enum.map(& &1.assigned_supermarket_id) |> Enum.reject(&is_nil/1)

      %{
        ingredient_id: ingredient_id,
        ingredient_name: first.ingredient.name,
        category: Atom.to_string(first.ingredient.category),
        unit: Atom.to_string(unit),
        total_quantity_milli: total_qty,
        rows_count: length(rows),
        in_cart_rows: in_cart,
        assigned_supermarket_id: assigned_ids |> List.first(),
        planned_dates:
          rows |> Enum.map(&Date.to_iso8601(&1.planned_date)) |> Enum.uniq() |> Enum.sort(),
        estimated_total_cents: Enum.reduce(rows, 0, &((&1.estimated_price_cents || 0) + &2))
      }
    end)
    |> Enum.sort_by(&{&1.category, &1.ingredient_name})
  end

  defp grouped_by_category(items) do
    items
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, rows} ->
      %{
        category: category,
        items: rows,
        total_quantity_milli: Enum.reduce(rows, 0, &(&1.total_quantity_milli + &2))
      }
    end)
    |> Enum.sort_by(& &1.category)
  end
end
