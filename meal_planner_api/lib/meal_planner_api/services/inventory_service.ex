defmodule MealPlannerApi.Services.InventoryService do
  import Ecto.Query, warn: false

  @moduledoc """
  Orchestration layer for inventory management use-cases.

  Coordinates:
  - Inventory view (grouped by freshness and category)
  - Adding/removing inventory items
  - Voice parsing for natural language quantity updates
  - Delta application with mutation logging

  Delegates to VoiceParserPort for natural language parsing.
  Delegates to data repos for persistence.
  """

  alias MealPlannerApi.Data.InventoryRepo
  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Voice.VoiceParserPort
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Catalog.Ingredient

  @warning_days 2

  # -------------------------------------------------------------------------
  # Inventory view
  # -------------------------------------------------------------------------

  @spec inventory_view(map()) :: {:ok, map()} | {:error, term()}
  def inventory_view(user) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user) do
      items = InventoryRepo.list_inventory_with_ingredient(identity.account_id)
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

  @spec freshness_status(map(), DateTime.t()) :: String.t()
  def freshness_status(item, now) do
    exp = item.expired_at || inferred_expired_at(item)
    days_until = Date.diff(exp, DateTime.to_date(now))

    cond do
      days_until < 0 -> "expired"
      days_until <= @warning_days -> "warning"
      true -> "ok"
    end
  end

  # -------------------------------------------------------------------------
  # Manual operations
  # -------------------------------------------------------------------------

  @spec add_extra_item(map(), map()) :: {:ok, map()} | {:error, term()}
  def add_extra_item(user, payload) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user),
         {:ok, ingredient_id} <- resolve_ingredient_id(payload),
         {:ok, quantity_milli} <- parse_positive_int(Map.get(payload, "quantity_milli")),
         {:ok, unit} <- parse_unit(Map.get(payload, "unit")),
         {:ok, _result} <-
           InventoryRepo.apply_delta(%{
             account_id: identity.account_id,
             ingredient_id: ingredient_id,
             unit: unit,
             source_kind: :extra,
             delta: quantity_milli,
             source_user_id: identity.user_id,
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
         event_id: nil
       }}
    end
  end

  @spec adjust_item_quantity(map(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def adjust_item_quantity(user, item_id, payload) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user),
         item when not is_nil(item) <-
           InventoryRepo.get_inventory_item_for_account(identity.account_id, item_id),
         {:ok, new_qty} <- parse_non_negative_int(Map.get(payload, "quantity_milli")),
         delta = new_qty - item.quantity_milli,
         {:ok, _delta_result} <-
           InventoryRepo.apply_delta(%{
             account_id: identity.account_id,
             ingredient_id: item.ingredient_id,
             unit: item.unit,
             source_kind: item.source_kind,
             delta: delta,
             source_user_id: identity.user_id,
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
         delta_applied_milli: delta
       }}
    else
      nil -> {:error, :item_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # -------------------------------------------------------------------------
  # Voice parsing
  # -------------------------------------------------------------------------

  @spec parse_voice_and_apply(map(), String.t(), module()) :: {:ok, [map()]} | {:error, term()}
  def parse_voice_and_apply(user, text, parser \\ VoiceParserPort) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user),
         items <- InventoryRepo.list_inventory_with_ingredient(identity.account_id),
         {:ok, deltas} <- parser.parse(text, items) do
      results =
        Enum.map(deltas, fn delta ->
          InventoryRepo.apply_delta(%{
            account_id: identity.account_id,
            ingredient_id: delta.inventory_item_id,
            unit: :grams,
            source_kind: :extra,
            delta: delta.quantity_milli,
            source_user_id: identity.user_id,
            trigger_type: :voice,
            operation: if(delta.quantity_milli >= 0, do: :add, else: :subtract),
            raw_voice_text: text
          })
        end)

      ok_results =
        Enum.filter(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      {:ok,
       Enum.map(ok_results, fn {:ok, r} ->
         %{
           ingredient_id: r.item.ingredient_id,
           quantity_delta_milli: r.item.quantity_milli - r.before_qty,
           operation: r[:mutation_event] && Atom.to_string(elem(r[:mutation_event].operation, 0))
         }
       end)}
    end
  end

  @spec get_inventory_item(map(), pos_integer()) :: {:ok, map()} | {:error, :not_found}
  def get_inventory_item(user, item_id) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user),
         item when not is_nil(item) <-
           InventoryRepo.get_inventory_item_for_account(identity.account_id, item_id) do
      {:ok,
       %{
         id: item.id,
         ingredient_id: item.ingredient_id,
         ingredient_name: item.ingredient.name,
         quantity_milli: item.quantity_milli,
         unit: Atom.to_string(item.unit)
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp inferred_expired_at(item) do
    acquired = item.acquired_at || DateTime.utc_now()

    default_days =
      case item.ingredient.category do
        :produce -> 5
        :dairy -> 7
        :meat -> 3
        _ -> 14
      end

    Date.add(DateTime.to_date(acquired), default_days)
  end

  defp group_by_category(items) do
    Enum.group_by(items, & &1.category)
  end

  # -------------------------------------------------------------------------
  # Inventory mutations: dispose, voice, rescue
  # -------------------------------------------------------------------------

  @spec dispose_item(map(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def dispose_item(user, item_id, payload) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user),
         item when not is_nil(item) <-
           InventoryRepo.get_inventory_item_for_account(identity.account_id, item_id),
         delta = -item.quantity_milli,
         {:ok, _} <-
           InventoryRepo.apply_delta(%{
             account_id: identity.account_id,
             ingredient_id: item.ingredient_id,
             unit: item.unit,
             source_kind: item.source_kind,
             delta: delta,
             source_user_id: identity.user_id,
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
         disposed_quantity_milli: item.quantity_milli
       }}
    else
      nil -> {:error, :inventory_item_not_found}
      {:error, _} = error -> error
    end
  end

  @spec voice_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def voice_preview(user, payload) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user),
         text when is_binary(text) <- Map.get(payload, "text"),
         items <- InventoryRepo.list_inventory_with_ingredient(identity.account_id) do
      ops = parse_voice_operations_internally(text, items)

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
  def voice_apply(user, payload) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user),
         operations when is_list(operations) <- Map.get(payload, "operations"),
         items <- InventoryRepo.list_inventory_with_ingredient(identity.account_id),
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

              case InventoryRepo.apply_delta(%{
                     account_id: identity.account_id,
                     ingredient_id: item.ingredient_id,
                     unit: item.unit,
                     source_kind: item.source_kind,
                     delta: delta,
                     source_user_id: identity.user_id,
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

  @spec rescue_plan(map(), map(), BudgetService.t()) :: {:ok, map()} | {:error, term()}
  def rescue_plan(user, payload, _budget) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user),
         ingredient_ids <- normalize_rescue_ingredient_ids(payload),
         false <- ingredient_ids == [] || ingredient_ids == nil,
         {:ok, recipe} <- pick_rescue_recipe(identity.account_id, ingredient_ids),
         {:ok, slot} <- first_available_slot(identity.account_id, Date.utc_today()),
         {:ok, scheduled} <-
           PlanningRepo.schedule_meal(%{
             account_id: identity.account_id,
             user_id: identity.user_id,
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
      {:error, _} = error -> error
      nil -> {:error, :no_rescue_recipe_found}
      _ -> {:error, :no_available_slot_today}
    end
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp parse_voice_operations_internally(text, items) do
    # Simple rule-based fallback parsing for voice operations
    fallback_parse_voice_operations(text, items)
  end

  defp fallback_parse_voice_operations(text, items) do
    lowered = String.downcase(text)

    # Spanish eating patterns
    spanish_eat_patterns = [
      "me comi",
      "me com\xED",
      "me comiera",
      "me comer\xED",
      "com\xED",
      "com\xED",
      "comiendo",
      "me terminé",
      "me termine",
      "me acabé",
      "consum\xed",
      "consumi",
      "consumiendo",
      "us\xe9",
      "use",
      "usando",
      "gast\xe9",
      "gaste",
      "gastando"
    ]

    # English patterns
    english_eat_patterns = [
      "use",
      "consume",
      "ate",
      "eaten",
      "finished",
      "used up",
      "consumed",
      "finished eating"
    ]

    all_patterns = spanish_eat_patterns ++ english_eat_patterns

    has_eating = Enum.any?(all_patterns, &String.contains?(lowered, &1))

    items
    |> Enum.map(fn item ->
      name = item.ingredient.name |> String.downcase()
      qty = item.quantity_milli

      # Check if item name is mentioned near eating pattern
      name_mentioned = String.contains?(lowered, name)

      # Check if any generic quantity is mentioned
      half_patterns = ["medio", "half", "la mitad", "mitad"]
      quarter_patterns = ["cuarto", "quarter", "un cuarto"]

      quantity_multiplier =
        cond do
          Enum.any?(half_patterns, &String.contains?(lowered, &1)) -> 0.5
          Enum.any?(quarter_patterns, &String.contains?(lowered, &1)) -> 0.25
          true -> 1.0
        end

      if has_eating and name_mentioned do
        %{
          "inventory_item_id" => item.id,
          "quantity_milli" => floor(qty * quantity_multiplier)
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_rescue_ingredient_ids(payload) do
    case Map.get(payload, "ingredient_ids") do
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  defp pick_rescue_recipe(_account_id, _ingredient_ids) do
    # Find ANY recipe from the database for rescue
    # This is a fallback for when no account-specific recipe exists
    try do
      recipes = MealPlannerApi.Repo.all(MealPlannerApi.Persistence.Catalog.Recipe)

      case recipes do
        [] -> {:error, :no_rescue_recipe_found}
        [first | _] -> {:ok, first}
      end
    rescue
      _ -> {:error, :no_rescue_recipe_found}
    end
  end

  defp first_available_slot(_account_id, _date) do
    # Default to dinner slot for rescue
    {:ok, :dinner}
  end

  defp iso_datetime(nil), do: nil
  defp iso_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso_datetime(%Date{} = d), do: Date.to_iso8601(d)
  defp iso_datetime(other), do: other

  defp resolve_ingredient_id(%{"ingredient_id" => id}) when is_integer(id), do: {:ok, id}

  defp resolve_ingredient_id(%{"ingredient_id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> {:ok, int}
      :error -> {:error, :invalid_ingredient_id}
    end
  end

  defp resolve_ingredient_id(%{"ingredient_name" => name}) do
    case MealPlannerApi.Repo.get_by(Ingredient, name: name) do
      nil -> {:error, :ingredient_not_found}
      ing -> {:ok, ing.id}
    end
  end

  defp resolve_ingredient_id(_), do: {:error, :missing_ingredient}

  defp parse_positive_int(nil), do: {:error, :missing_quantity}
  defp parse_positive_int(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_positive_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> {:ok, n}
      _ -> {:error, :invalid_quantity}
    end
  end

  defp parse_positive_int(_), do: {:error, :invalid_quantity}

  defp parse_non_negative_int(nil), do: {:error, :missing_quantity}
  defp parse_non_negative_int(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp parse_non_negative_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_quantity}
    end
  end

  defp parse_non_negative_int(_), do: {:error, :invalid_quantity}

  defp parse_unit(nil), do: {:ok, :grams}
  defp parse_unit(:grams), do: {:ok, :grams}
  defp parse_unit("grams"), do: {:ok, :grams}
  defp parse_unit(:ml), do: {:ok, :ml}
  defp parse_unit("ml"), do: {:ok, :ml}
  defp parse_unit(:units), do: {:ok, :units}
  defp parse_unit("units"), do: {:ok, :units}
  defp parse_unit(_), do: {:ok, :grams}
end
