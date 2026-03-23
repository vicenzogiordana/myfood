defmodule MealPlannerApi.InventoryHub do
  @moduledoc """
  Inventory orchestration for Vista 5: categorized inventory, manual/voice mutations,
  and rescue planning from expiring ingredients.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.AI
  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Persistence.Catalog.Recipe
  alias MealPlannerApi.Persistence.Catalog.RecipeIngredient
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Inventory
  alias MealPlannerApi.Persistence.Inventory.InventoryItem
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Repo

  @warning_days 2
  @slots [:lunch, :dinner, :snack, :breakfast]

  @spec inventory_view(map()) :: {:ok, map()} | {:error, term()}
  def inventory_view(current_user) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user) do
      items = Inventory.list_inventory_with_ingredient(ids.account_id)
      now = DateTime.utc_now()

      decorated =
        Enum.map(items, fn item ->
          status = freshness_status(item, now)

          %{
            id: item.id,
            ingredient_id: item.ingredient_id,
            ingredient_name: item.ingredient.name,
            category: Atom.to_string(item.ingredient.category),
            quantity_milli: item.quantity_milli,
            unit: Atom.to_string(item.unit),
            source_kind: Atom.to_string(item.source_kind),
            acquired_at: iso_datetime(item.acquired_at),
            expired_at: iso_datetime(item.expired_at),
            inferred_expired_at: iso_datetime(inferred_expired_at(item)),
            freshness_status: status
          }
        end)

      {:ok,
       %{
         sections: %{
           ok: Enum.filter(decorated, &(&1.freshness_status == "ok")),
           warning: Enum.filter(decorated, &(&1.freshness_status == "warning")),
           expired: Enum.filter(decorated, &(&1.freshness_status == "expired"))
         },
         by_category: group_by_category(decorated),
         extras: Enum.filter(decorated, &(&1.source_kind == "extra")),
         totals: %{
           items_count: length(decorated),
           warning_count: Enum.count(decorated, &(&1.freshness_status == "warning")),
           expired_count: Enum.count(decorated, &(&1.freshness_status == "expired"))
         }
       }}
    end
  end

  @spec add_extra_item(map(), map()) :: {:ok, map()} | {:error, term()}
  def add_extra_item(current_user, payload) when is_map(payload) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, ingredient_id} <- resolve_ingredient_id(payload),
         {:ok, quantity_milli} <- parse_positive_int(Map.get(payload, "quantity_milli")),
         {:ok, unit} <- parse_unit(Map.get(payload, "unit")),
         {:ok, result} <-
           Inventory.apply_delta_and_log(%{
             account_id: ids.account_id,
             ingredient_id: ingredient_id,
             unit: unit,
             source_kind: :extra,
             delta: quantity_milli,
             source_user_id: ids.user_id,
             trigger_type: :manual,
             operation: :add,
             metadata: %{reason: "manual_extra"}
           }) do
      {:ok,
       %{
         status: "ok",
         operation: "add_extra",
         quantity_milli: quantity_milli,
         unit: Atom.to_string(unit),
         event_id: result[:mutation_event].id
       }}
    end
  end

  @spec adjust_item_quantity(map(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def adjust_item_quantity(current_user, item_id, payload)
      when is_binary(item_id) and is_map(payload) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         item when not is_nil(item) <-
           Inventory.get_inventory_item_for_account(ids.account_id, item_id),
         {:ok, new_qty} <- parse_non_negative_int(Map.get(payload, "quantity_milli")),
         delta <- new_qty - item.quantity_milli,
         {:ok, result} <-
           Inventory.apply_delta_and_log(%{
             account_id: ids.account_id,
             ingredient_id: item.ingredient_id,
             unit: item.unit,
             source_kind: item.source_kind,
             delta: delta,
             source_user_id: ids.user_id,
             trigger_type: :manual,
             operation: :set,
             metadata: %{reason: "manual_adjust", inventory_item_id: item.id}
           }) do
      {:ok,
       %{
         item_id: item.id,
         ingredient_name: item.ingredient.name,
         quantity_before_milli: item.quantity_milli,
         quantity_after_milli: new_qty,
         quantity_delta_milli: delta,
         event_id: result[:mutation_event].id
       }}
    else
      nil -> {:error, :inventory_item_not_found}
      {:error, _} = error -> error
    end
  end

  @spec dispose_item(map(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def dispose_item(current_user, item_id, payload) when is_binary(item_id) and is_map(payload) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         item when not is_nil(item) <-
           Inventory.get_inventory_item_for_account(ids.account_id, item_id),
         delta <- -item.quantity_milli,
         {:ok, result} <-
           Inventory.apply_delta_and_log(%{
             account_id: ids.account_id,
             ingredient_id: item.ingredient_id,
             unit: item.unit,
             source_kind: item.source_kind,
             delta: delta,
             source_user_id: ids.user_id,
             trigger_type: :manual,
             operation: :delete,
             metadata: %{
               reason: Map.get(payload, "reason", "disposed"),
               inventory_item_id: item.id
             }
           }) do
      {:ok,
       %{
         item_id: item.id,
         ingredient_name: item.ingredient.name,
         disposed_quantity_milli: item.quantity_milli,
         event_id: result[:mutation_event].id
       }}
    else
      nil -> {:error, :inventory_item_not_found}
      {:error, _} = error -> error
    end
  end

  @spec voice_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def voice_preview(current_user, payload) when is_map(payload) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         text when is_binary(text) <- Map.get(payload, "text"),
         items <- Inventory.list_inventory_with_ingredient(ids.account_id) do
      ops = parse_voice_operations(text, items)

      {:ok,
       %{
         raw_text: text,
         operations: ops,
         confirmation_required: true
       }}
    else
      _ -> {:error, :invalid_voice_payload}
    end
  end

  @spec voice_apply(map(), map()) :: {:ok, map()} | {:error, term()}
  def voice_apply(current_user, payload) when is_map(payload) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         operations when is_list(operations) <- Map.get(payload, "operations"),
         items <- Inventory.list_inventory_with_ingredient(ids.account_id),
         by_id <- Map.new(items, &{&1.id, &1}) do
      moved =
        Enum.reduce_while(operations, 0, fn op, acc ->
          item = Map.get(by_id, Map.get(op, "inventory_item_id"))
          qty = Map.get(op, "quantity_milli")

          cond do
            is_nil(item) or not is_integer(qty) or qty <= 0 ->
              {:cont, acc}

            true ->
              delta = -min(qty, item.quantity_milli)

              case Inventory.apply_delta_and_log(%{
                     account_id: ids.account_id,
                     ingredient_id: item.ingredient_id,
                     unit: item.unit,
                     source_kind: item.source_kind,
                     delta: delta,
                     source_user_id: ids.user_id,
                     trigger_type: :voice,
                     operation: :subtract,
                     raw_voice_text: Map.get(payload, "raw_text"),
                     metadata: %{inventory_item_id: item.id}
                   }) do
                {:ok, _} -> {:cont, acc + 1}
                {:error, _} -> {:halt, acc}
              end
          end
        end)

      {:ok, %{status: "ok", applied_operations: moved}}
    else
      _ -> {:error, :invalid_voice_payload}
    end
  end

  @spec rescue_plan(map(), map()) :: {:ok, map()} | {:error, term()}
  def rescue_plan(current_user, payload) when is_map(payload) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         ingredient_ids <- normalize_rescue_ingredient_ids(ids.account_id, payload),
         false <- ingredient_ids == [],
         recipe when not is_nil(recipe) <- pick_rescue_recipe(ids.account_id, ingredient_ids),
         {:ok, slot} <- first_available_slot(ids.account_id, Date.utc_today()),
         {:ok, scheduled} <-
           Planning.schedule_meal(%{
             account_id: ids.account_id,
             date: Date.utc_today(),
             slot: slot,
             recipe_id: recipe.id,
             is_cooked: false
           }) do
      {:ok,
       %{
         status: "scheduled",
         scheduled_meal_id: scheduled.id,
         date: Date.to_iso8601(scheduled.date),
         slot: Atom.to_string(slot),
         recipe: %{id: recipe.id, name: recipe.name},
         rescued_ingredient_ids: ingredient_ids
       }}
    else
      true -> {:error, :no_ingredients_selected}
      nil -> {:error, :no_rescue_recipe_found}
      {:error, _} = error -> error
      _ -> {:error, :no_available_slot_today}
    end
  end

  defp parse_voice_operations(text, items) do
    ai_ops = parse_with_ai(text, items)

    if ai_ops != [] do
      ai_ops
    else
      fallback_parse_voice_operations(text, items)
    end
  end

  defp parse_with_ai(text, items) do
    prompt =
      """
      Extrae consumos desde texto de voz y devuelve JSON con clave operations.
      Formato exacto: {\"operations\":[{\"inventory_item_id\":\"...\",\"quantity_milli\":123}]}
      Solo usa estos items válidos: #{Jason.encode!(Enum.map(items, fn i -> %{id: i.id, name: i.ingredient.name, quantity_milli: i.quantity_milli} end))}
      Texto: #{text}
      """

    case AI.generate_text(prompt) do
      {:ok, raw} ->
        with {:ok, parsed} <- Jason.decode(raw),
             ops when is_list(ops) <- Map.get(parsed, "operations") do
          Enum.filter(ops, fn op ->
            is_binary(op["inventory_item_id"]) and is_integer(op["quantity_milli"])
          end)
        else
          _ -> []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp fallback_parse_voice_operations(text, items) do
    lowered = String.downcase(text)

    Enum.reduce(items, [], fn item, acc ->
      name = String.downcase(item.ingredient.name)

      cond do
        String.contains?(lowered, "mitad del kilo de " <> name) ->
          [%{"inventory_item_id" => item.id, "quantity_milli" => 500} | acc]

        String.contains?(lowered, "medio " <> name) ->
          [
            %{"inventory_item_id" => item.id, "quantity_milli" => div(item.quantity_milli, 2)}
            | acc
          ]

        String.contains?(lowered, name) ->
          # Mention without explicit quantity defaults to 1/4 of current stock.
          [
            %{
              "inventory_item_id" => item.id,
              "quantity_milli" => max(div(item.quantity_milli, 4), 1)
            }
            | acc
          ]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_rescue_ingredient_ids(account_id, payload) do
    ingredient_ids = Map.get(payload, "ingredient_ids", [])
    inventory_item_ids = Map.get(payload, "inventory_item_ids", [])

    ids_from_inventory =
      if inventory_item_ids == [] do
        []
      else
        Inventory.list_inventory_with_ingredient(account_id)
        |> Enum.filter(&(&1.id in inventory_item_ids))
        |> Enum.map(& &1.ingredient_id)
      end

    (ingredient_ids ++ ids_from_inventory)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp pick_rescue_recipe(account_id, ingredient_ids) do
    query =
      from(r in Recipe,
        join: ri in RecipeIngredient,
        on: ri.recipe_id == r.id,
        where:
          (is_nil(r.account_id) or r.account_id == ^account_id) and
            ri.ingredient_id in ^ingredient_ids,
        group_by: [r.id, r.name],
        order_by: [desc: count(ri.ingredient_id)],
        limit: 1,
        select: %{id: r.id, name: r.name}
      )

    Repo.one(query)
  end

  defp first_available_slot(account_id, date) do
    used =
      Planning.list_scheduled_meals(account_id, date, date)
      |> Enum.map(& &1.slot)
      |> MapSet.new()

    case Enum.find(@slots, fn slot -> not MapSet.member?(used, slot) end) do
      nil -> {:error, :no_available_slot_today}
      slot -> {:ok, slot}
    end
  end

  defp inferred_expired_at(%InventoryItem{expired_at: %DateTime{} = dt}), do: dt

  defp inferred_expired_at(%InventoryItem{
         acquired_at: %DateTime{} = acquired,
         ingredient: ingredient
       }) do
    days = default_shelf_life_days(ingredient.category)
    DateTime.add(acquired, days * 86_400, :second)
  end

  defp inferred_expired_at(_), do: nil

  defp freshness_status(item, now) do
    case inferred_expired_at(item) do
      nil ->
        "ok"

      exp ->
        days = Date.diff(DateTime.to_date(exp), DateTime.to_date(now))

        cond do
          days < 0 -> "expired"
          days <= @warning_days -> "warning"
          true -> "ok"
        end
    end
  end

  defp default_shelf_life_days(:carnes), do: 3
  defp default_shelf_life_days(:lacteos), do: 5
  defp default_shelf_life_days(:verduras), do: 5
  defp default_shelf_life_days(:frutas), do: 7
  defp default_shelf_life_days(:congelados), do: 30
  defp default_shelf_life_days(:granos), do: 120
  defp default_shelf_life_days(:no_perecederos), do: 180
  defp default_shelf_life_days(_), do: 14

  defp parse_positive_int(v) when is_integer(v) and v > 0, do: {:ok, v}
  defp parse_positive_int(_), do: {:error, :invalid_quantity}

  defp parse_non_negative_int(v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp parse_non_negative_int(_), do: {:error, :invalid_quantity}

  defp parse_unit("g"), do: {:ok, :g}
  defp parse_unit("ml"), do: {:ok, :ml}
  defp parse_unit("unit"), do: {:ok, :unit}
  defp parse_unit(_), do: {:error, :invalid_unit}

  defp resolve_ingredient_id(%{"ingredient_id" => ingredient_id}) when is_binary(ingredient_id),
    do: {:ok, ingredient_id}

  defp resolve_ingredient_id(%{"ingredient_name" => name}) when is_binary(name) do
    trimmed = String.trim(name)

    query =
      from(i in Ingredient,
        where: fragment("lower(?)", i.name) == ^String.downcase(trimmed),
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :ingredient_not_found}
      ingredient -> {:ok, ingredient.id}
    end
  end

  defp resolve_ingredient_id(_), do: {:error, :ingredient_not_found}

  defp group_by_category(items) do
    items
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, rows} -> %{category: category, items: rows} end)
    |> Enum.sort_by(& &1.category)
  end

  defp iso_datetime(nil), do: nil
  defp iso_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
