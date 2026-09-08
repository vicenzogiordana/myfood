defmodule MealPlannerApi.Services.PlanningCandidateBuilder do
  @moduledoc """
  Builds the only recipe candidates that may cross into the optimizer.

  Candidate eligibility is server-owned: account scope and selected active
  participants are resolved here rather than accepted from an AI or client
  payload. Inventory is represented only as an objective signal.
  """

  alias MealPlannerApi.Data.{PlanningRepo, RecipeRepo}
  alias MealPlannerApi.Services.InventoryService

  @type dated_slot :: %{required(:date) => Date.t(), required(:slot) => atom() | String.t()}

  @spec build_candidate_set(Ecto.UUID.t(), [dated_slot()], [Ecto.UUID.t()]) ::
          {:ok, %{slots: [map()], validation_context: map()}}
          | {:error, :no_candidates_for_slot, map()}
  def build_candidate_set(account_id, dated_slots, participant_ids),
    do: build_candidate_set(account_id, dated_slots, participant_ids, :strict)

  @doc "Builds the existing candidates available to the legacy planning preview flow."
  @spec build_available_candidate_set(Ecto.UUID.t(), [dated_slot()], [Ecto.UUID.t()]) ::
          {:ok, %{slots: [map()], validation_context: map()}}
  def build_available_candidate_set(account_id, dated_slots, participant_ids),
    do: build_candidate_set(account_id, dated_slots, participant_ids, :available)

  defp build_candidate_set(_account_id, dated_slots, participant_ids, :strict)
       when not is_list(dated_slots) or dated_slots == [] or not is_list(participant_ids) or
              participant_ids == [],
       do: {:error, :no_candidates_for_slot, %{}}

  defp build_candidate_set(account_id, dated_slots, participant_ids, :available)
       when not is_list(dated_slots) or not is_list(participant_ids) or participant_ids == [],
       do: {:ok, %{slots: [], validation_context: %{account_id: account_id, participant_ids: []}}}

  defp build_candidate_set(account_id, dated_slots, participant_ids, mode)
       when is_list(dated_slots) and is_list(participant_ids) do
    inventory = InventoryService.list_for_account(account_id)
    slots = dated_slots |> Enum.map(&to_string(&1.slot)) |> Enum.uniq()

    candidates_by_slot =
      account_id
      |> PlanningRepo.candidate_recipe_ids_for_slots(participant_ids, slots)
      |> PlanningRepo.recipes_for_ids(account_id)
      |> build_candidates_by_slot(inventory)

    build_slots(dated_slots, candidates_by_slot, mode)
    |> case do
      {:ok, slots} ->
        slots = Enum.reverse(slots)

        {:ok,
         %{
           slots: slots,
           validation_context: %{account_id: account_id, participant_ids: participant_ids}
         }}

      error ->
        error
    end
  end

  defp build_slots(dated_slots, candidates_by_slot, :strict) do
    Enum.reduce_while(dated_slots, {:ok, []}, fn %{date: date, slot: slot} = descriptor,
                                                 {:ok, slots} ->
      slot_name = to_string(slot)

      case Map.get(candidates_by_slot, slot_name, []) do
        [] ->
          {:halt, {:error, :no_candidates_for_slot, Map.take(descriptor, [:date, :slot])}}

        candidates ->
          {:cont, {:ok, [candidate_slot(date, slot_name, candidates) | slots]}}
      end
    end)
  end

  defp build_slots(dated_slots, candidates_by_slot, :available) do
    slots =
      Enum.flat_map(dated_slots, fn %{date: date, slot: slot} ->
        slot_name = to_string(slot)

        case Map.get(candidates_by_slot, slot_name, []) do
          [] -> []
          candidates -> [candidate_slot(date, slot_name, candidates)]
        end
      end)

    {:ok, Enum.reverse(slots)}
  end

  defp candidate_slot(date, slot_name, candidates) do
    %{date: Date.to_iso8601(date), slot: slot_name, candidates: candidates}
  end

  defp build_candidates_by_slot(recipes, inventory) do
    costs = PlanningRepo.latest_recipe_costs(Enum.map(recipes, & &1.id))
    ingredients_by_recipe = RecipeRepo.list_ingredients_for_recipes(Enum.map(recipes, & &1.id))

    recipes
    |> Enum.sort_by(&{&1.slot, &1.id, &1.name})
    |> Enum.group_by(& &1.slot, fn recipe ->
      %{
        "recipe_id" => recipe.id,
        "label" => recipe.name,
        "estimated_cost_cents" => Map.get(costs, recipe.id, 0),
        "protein_g_per_serving" => decimal_number(recipe.protein_g_per_serving),
        "carbs_g_per_serving" => decimal_number(recipe.carbs_g_per_serving),
        "fat_g_per_serving" => decimal_number(recipe.fat_g_per_serving),
        "calories_per_serving" => recipe.calories_per_serving || 0,
        "inventory_hit_count" =>
          inventory_hits(Map.get(ingredients_by_recipe, recipe.id, []), inventory)
      }
    end)
  end

  defp inventory_hits(recipe_ingredients, inventory) do
    Enum.count(recipe_ingredients, fn ingredient ->
      Enum.any?(inventory, fn item ->
        item.ingredient_id == ingredient.ingredient_id and item.unit == ingredient.unit and
          item.quantity_milli >= ingredient.quantity_milli
      end)
    end)
  end

  defp decimal_number(nil), do: 0
  defp decimal_number(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_number(value) when is_number(value), do: value
end
