# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule MealPlannerApi.PrototypePlanningLoop.Validator do
  @moduledoc """
  Hard-constraint check that runs outside the model. A proposal is shown as
  valid only when this module says so: every day/slot filled exactly once with
  a catalogue recipe of that slot, no allergen of any member, total cost within
  the weekly budget.
  """

  alias MealPlannerApi.PrototypePlanningLoop.Fixtures

  @doc """
  `meals` is a list of maps with string keys `"day"`, `"slot"`, `"recipe_id"`.
  Returns a verdict map; `valid` is the only field that grants validity.
  """
  def validate(household, meals) when is_list(meals) do
    expected = for day <- Fixtures.days(), slot <- Fixtures.slots(), do: {day, slot}
    cells = Enum.frequencies_by(meals, &{&1["day"], &1["slot"]})

    coverage =
      Enum.flat_map(expected, fn {day, slot} = cell ->
        case Map.get(cells, cell, 0) do
          1 -> []
          0 -> [%{rule: "slot_unfilled", day: day, slot: slot}]
          _ -> [%{rule: "slot_filled_twice", day: day, slot: slot}]
        end
      end)

    per_meal = Enum.flat_map(meals, &meal_violations(household, &1, expected))

    total = meals |> Enum.map(&Fixtures.recipe(&1["recipe_id"])) |> Enum.reject(&is_nil/1)
    total_cost_cents = total |> Enum.map(& &1.cost_cents) |> Enum.sum()

    budget =
      if total_cost_cents > household.weekly_budget_cents do
        [
          %{
            rule: "over_budget",
            total_cost_cents: total_cost_cents,
            weekly_budget_cents: household.weekly_budget_cents
          }
        ]
      else
        []
      end

    violations = coverage ++ per_meal ++ budget

    %{
      valid: violations == [],
      violations: violations,
      meals: meals,
      total_cost_cents: total_cost_cents,
      weekly_budget_cents: household.weekly_budget_cents
    }
  end

  def validate(household, _meals), do: validate(household, [])

  defp meal_violations(household, meal, expected) do
    day = meal["day"]
    slot = meal["slot"]
    recipe = Fixtures.recipe(meal["recipe_id"])

    cond do
      {day, slot} not in expected ->
        [%{rule: "unknown_day_or_slot", day: day, slot: slot}]

      is_nil(recipe) ->
        [%{rule: "unknown_recipe", day: day, slot: slot, recipe_id: meal["recipe_id"]}]

      recipe.slot != slot ->
        [%{rule: "recipe_not_for_slot", day: day, slot: slot, recipe_id: recipe.id}]

      true ->
        for conflict <- Fixtures.allergen_conflicts(household, recipe) do
          %{
            rule: "allergen",
            day: day,
            slot: slot,
            recipe_id: recipe.id,
            member: conflict.member,
            allergen: conflict.allergen
          }
        end
    end
  end
end
