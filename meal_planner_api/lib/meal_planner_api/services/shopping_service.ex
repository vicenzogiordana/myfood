defmodule MealPlannerApi.Services.ShoppingService do
  import Ecto.Query, warn: false

  @moduledoc """
  Shopping list orchestration.

  Builds, manages, and resolves shopping lists with supermarket assignments
  and price estimates.
  """

  alias MealPlannerApi.Data.ShoppingRepo
  alias MealPlannerApi.Data.RecipeRepo
  alias MealPlannerApi.Data.InventoryRepo
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Shopping
  alias MealPlannerApi.Repo

  # -------------------------------------------------------------------------
  # Shopping list
  # -------------------------------------------------------------------------

  @spec get_shopping_list(map(), map()) :: {:ok, map()} | {:error, term()}
  def get_shopping_list(user, params \\ %{}) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        account_id = identity.account_id
        from_date = parse_date(Map.get(params, "from_date"), Date.utc_today())
        end_date = parse_date(Map.get(params, "to_date"), Date.add(from_date, 6))

        # Auto-archive past items
        prune_past_items(account_id, from_date)

        # Build items from scheduled meals (if not already created)
        _ = ensure_shopping_items_from_schedule(account_id, from_date, end_date)

        items = Shopping.list_pending_items_with_context(account_id, from_date, end_date)
        in_cart = Shopping.list_in_cart_items_with_context(account_id, from_date, end_date)

        # Group items by ingredient_id, aggregating quantities and prices
        grouped =
          Enum.group_by(items ++ in_cart, & &1.ingredient_id)
          |> Enum.map(fn {_ingredient_id, grouped_items} ->
            first = hd(grouped_items)
            %{ingredient_id: first.ingredient_id}
            |> Map.merge(serialize_shopping_item(first))
            |> Map.put(:total_quantity_milli, Enum.reduce(grouped_items, 0, fn i, acc -> acc + (i.quantity_milli || 0) end))
            |> Map.put(:item_count, length(grouped_items))
          end)

        {:ok,
         %{
           items: grouped,
           pending_count: length(items),
           in_cart_count: length(in_cart),
           total_estimated_cents: Enum.reduce(items, 0, &((&1.estimated_price_cents || 0) + &2))
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Ensure shopping items exist for all scheduled meals in the date range
  # (only for ingredients that don't already have items in the range)
  defp ensure_shopping_items_from_schedule(account_id, from_date, to_date) do
    # Get scheduled meals in range
    scheduled_meals =
      from(m in MealPlannerApi.Persistence.Planning.ScheduledMeal,
        where: m.account_id == ^account_id,
        where: m.date >= ^from_date and m.date <= ^to_date,
        where: m.is_cooked == false,
        preload: [recipe: [recipe_ingredients: :ingredient]]
      )
      |> Repo.all()

    # Get existing item ingredient_ids in range to avoid duplicates
    existing_ingredient_ids =
      from(i in MealPlannerApi.Persistence.Shopping.ShoppingItem,
        where: i.account_id == ^account_id,
        where: i.planned_date >= ^from_date and i.planned_date <= ^to_date,
        where: i.status == :pending,
        select: i.ingredient_id,
        distinct: true
      )
      |> Repo.all()
      |> MapSet.new()

    # For each meal, ensure shopping items exist only for new ingredients
    Enum.each(scheduled_meals, fn meal ->
      if meal.recipe && meal.recipe.recipe_ingredients do
        Enum.each(meal.recipe.recipe_ingredients || [], fn ri ->
          if ri.ingredient_id && ri.quantity_milli &&
             not MapSet.member?(existing_ingredient_ids, ri.ingredient_id) do
            Shopping.create_shopping_item(%{
              account_id: account_id,
              scheduled_meal_id: meal.id,
              planned_date: meal.date,
              ingredient_id: ri.ingredient_id,
              quantity_milli: ri.quantity_milli,
              unit: ri.unit || :g,
              status: :pending
            })
          end
        end)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  # Prune/archive past-dated items (planned_date before from_date)
  defp prune_past_items(account_id, from_date) do
    past_items =
      Ecto.Query.from(i in MealPlannerApi.Persistence.Shopping.ShoppingItem,
        where: i.account_id == ^account_id,
        where: not is_nil(i.planned_date),
        where: i.planned_date < ^from_date,
        where: i.status == :pending
      )
      |> Repo.all()

    Enum.each(past_items, fn item ->
      Repo.update!(Ecto.Changeset.change(item, %{status: :archived}))
    end)
  rescue
    _ -> :ok
  end

  @spec build_shopping_list_from_schedule(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_shopping_list_from_schedule(user, params \\ %{}) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        account_id = identity.account_id
        from_date = parse_date(Map.get(params, "from_date"), Date.utc_today())
        _end_date = parse_date(Map.get(params, "to_date"), Date.add(from_date, 6))
        recipe_ids = Map.get(params, "recipe_ids", [])

        {:ok, session} =
          ShoppingRepo.create_checkout_session(%{
            account_id: account_id,
            status: :draft,
            started_at: DateTime.utc_now()
          })

        persisted = build_items_from_recipes(account_id, recipe_ids, session.id)

        {:ok,
         %{
           checkout_session_id: session.id,
           items_generated: length(persisted),
           items: Enum.map(persisted, &serialize_shopping_item/1)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec mark_in_cart(map(), [pos_integer()]) :: {:ok, map()} | {:error, term()}
  def mark_in_cart(user, item_ids) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, _identity} ->
        updated =
          Enum.map(item_ids, fn id ->
            ShoppingRepo.toggle_shopping_item_checked(id)
          end)

        ok =
          Enum.count(updated, fn
            {:ok, _} -> true
            _ -> false
          end)

        {:ok, %{item_ids: item_ids, marked_count: ok}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec assign_supermarket(map(), pos_integer(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def assign_supermarket(user, item_id, supermarket_id) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, _identity} ->
        item = ShoppingRepo.toggle_shopping_item_checked(item_id)

        case item do
          {:ok, updated_item} ->
            case ShoppingRepo.update_shopping_item(updated_item, %{supermarket_id: supermarket_id}) do
              {:ok, final_item} -> {:ok, serialize_shopping_item(final_item)}
              {:error, reason} -> {:error, reason}
            end

          {:error, _} ->
            {:error, :item_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------------
  # Checkout sessions
  # -------------------------------------------------------------------------

  @spec start_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  def start_checkout_session(user) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        {:ok, session} =
          ShoppingRepo.create_checkout_session(%{
            account_id: identity.account_id,
            status: :draft,
            started_at: DateTime.utc_now()
          })

        {:ok, %{session_id: session.id, status: Atom.to_string(session.status)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec confirm_checkout(map(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def confirm_checkout(user, session_id, payload) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        session = ShoppingRepo.get_checkout_session_for_account(identity.account_id, session_id)

        case session do
          nil ->
            {:error, :session_not_found}

          _ ->
            actual_total = Map.get(payload, "actual_total_cents", 0)

            {:ok, updated} =
              ShoppingRepo.update_checkout_session(session, %{
                status: :completed,
                actual_total_cents: actual_total,
                completed_at: DateTime.utc_now()
              })

            {:ok, serialize_checkout_session(updated)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Date-range based checkout: create session from items in range
  @spec create_checkout_from_range(map(), Date.t(), Date.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_checkout_from_range(user, start_date, end_date, checkout_type) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user) do
      # Get items in date range (start_date <= planned_date <= end_date)
      items =
        Shopping.list_items_for_account(identity.account_id)
        |> Enum.filter(fn item ->
          item.planned_date != nil and
          Date.compare(item.planned_date, start_date) in [:gt, :eq] and
          Date.compare(item.planned_date, end_date) in [:lt, :eq]
        end)

      if items == [], do: {:error, :no_items_in_range}

      # Calculate estimated total
      estimated_total =
        items
        |> Enum.reject(&is_nil(&1.estimated_price_cents))
        |> Enum.reduce(0, fn item, acc -> acc + item.estimated_price_cents end)

      # Create checkout session first
      checkout_type_atom = if checkout_type == "online", do: :online, else: :physical

      {:ok, session} =
        ShoppingRepo.create_checkout_session(%{
          account_id: identity.account_id,
          status: :pending_delivery,
          checkout_type: checkout_type_atom,
          estimated_total_cents: estimated_total,
          started_at: DateTime.utc_now()
        })

      # Update items to link to session and set status
      Enum.each(items, fn item ->
        ShoppingRepo.update_shopping_item(item, %{
          status: :pending_delivery
        })
      end)

      {:ok,
       %{
         checkout_session_id: session.id,
         status: "pending_delivery",
         moved_to_inventory_count: 0,
         item_count: length(items),
         estimated_total_cents: estimated_total
       }}
    end
  end

  @spec confirm_delivery(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def confirm_delivery(user, checkout_session_id) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user) do
      session =
        ShoppingRepo.get_checkout_session_for_account(identity.account_id, checkout_session_id)

      case session do
        nil ->
          {:error, :session_not_found}

        _ ->
          # Get items linked to this session and move them to inventory
          items =
            Shopping.list_items_for_account(identity.account_id)
            |> Enum.filter(fn item ->
              item.status == :pending_delivery
            end)

          moved_count = move_items_to_inventory(items)

          # Mark items as checked out
          Enum.each(items, fn item ->
          Shopping.update_shopping_item(item, %{status: :checked_out})
          end)

          {:ok, updated} =
            ShoppingRepo.update_checkout_session(session, %{
              status: :completed,
              completed_at: DateTime.utc_now(),
              delivered_at: DateTime.utc_now()
            })

          {:ok, Map.merge(serialize_checkout_session(updated), %{
            moved_to_inventory_count: moved_count
          })}
      end
    end
  end

  defp move_items_to_inventory([]), do: 0
  defp move_items_to_inventory(items) do
    Enum.reduce(items, 0, fn item, acc ->
      case InventoryRepo.create_inventory_item(%{
        account_id: item.account_id,
        ingredient_id: item.ingredient_id,
        quantity_milli: item.quantity_milli,
        unit: item.unit,
        source: :shopping_checkout
      }) do
        {:ok, _} -> acc + 1
        {:error, _} -> acc
      end
    end)
  end

  # -------------------------------------------------------------------------
  # Supermarkets
  # -------------------------------------------------------------------------

  @spec list_supermarkets(map()) :: {:ok, [map()]} | {:error, term()}
  def list_supermarkets(user) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, _identity} ->
        supermarkets = ShoppingRepo.list_supermarkets()
        {:ok, Enum.map(supermarkets, &serialize_supermarket/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp build_items_from_recipes(_account_id, [], _session_id), do: []

  defp build_items_from_recipes(_account_id, recipe_ids, session_id) when is_list(recipe_ids) do
    recipes =
      recipe_ids
      |> Enum.map(&RecipeRepo.get_recipe!/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Repo.preload(&1, :recipe_ingredients))

    Enum.flat_map(recipes, fn recipe ->
      Enum.map(recipe.recipe_ingredients || [], fn ri ->
        ShoppingRepo.create_shopping_item(%{
          checkout_session_id: session_id,
          ingredient_id: ri.ingredient_id,
          quantity_milli: ri.quantity_milli,
          unit: ri.unit,
          is_checked: false,
          is_in_cart: false
        })
      end)
    end)
    |> Enum.filter(fn
      {:ok, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:ok, item} -> item end)
  end

  defp parse_date(nil, default), do: default

  defp parse_date(d, _default) when is_binary(d) do
    case Date.from_iso8601(d) do
      {:ok, date} -> date
      :error -> nil
    end
  end

  defp parse_date(d, _default), do: d

  defp serialize_shopping_item(i) do
    category =
      case i do
        %{ingredient: %{category: cat}} when cat != nil -> Atom.to_string(cat)
        _ -> nil
      end

    %{
      id: i.id,
      ingredient_id: i.ingredient_id,
      ingredient_name: i.ingredient && i.ingredient.name,
      category: category,
      quantity_milli: i.quantity_milli,
      unit: Atom.to_string(i.unit),
      status: Atom.to_string(i.status),
      estimated_price_cents: i.estimated_price_cents,
      supermarket_id: i.assigned_supermarket_id,
      supermarket_name: i.assigned_supermarket && i.assigned_supermarket.name
    }
  end

  defp serialize_checkout_session(s) do
    %{
      id: s.id,
      status: Atom.to_string(s.status),
      estimated_total_cents: s.total_cents || 0,
      actual_total_cents: s.total_cents || 0,
      started_at: iso_datetime(s.inserted_at),
      completed_at: iso_datetime(s.confirmed_at),
      delivered_at: iso_datetime(s.invalidated_at)
    }
  end

  defp serialize_supermarket(m) do
    %{
      id: m.id,
      name: m.name,
      address: m.address,
      is_preferred: m.is_preferred
    }
  end

  defp iso_datetime(nil), do: nil
  defp iso_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso_datetime(%Date{} = d), do: Date.to_iso8601(d)
end
