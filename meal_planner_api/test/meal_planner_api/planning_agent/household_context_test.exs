defmodule MealPlannerApi.PlanningAgent.HouseholdContextTest do
  @moduledoc """
  The model instructions must only claim code enforcement for what code
  actually enforces (spec #93): Restrictions are enforced; the grocery
  budget and the Nutrition Goal are not validated yet.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.HouseholdContext

  @range {~D[2026-11-02], ~D[2026-11-03]}

  defp context do
    %{
      account_id: Ecto.UUID.generate(),
      members: [],
      forbidden_tags: MapSet.new([:contains_meat]),
      allergic_ingredient_ids: MapSet.new([Ecto.UUID.generate()]),
      disliked_ingredients: ["Fictitious celery"],
      budget_cents: 12_345,
      nutrition_goal: %{
        calories: %{min: 1800, max: 2200},
        protein_g: %{min: 90, max: 140},
        carbs_g: %{min: 180, max: 260},
        fat_g: %{min: 50, max: 80}
      },
      consent?: true
    }
  end

  defp section(instructions, heading) do
    [_before, rest] = String.split(instructions, heading, parts: 2)
    rest |> String.split("\n\n", parts: 2) |> hd()
  end

  test "only Restrictions are listed under the code-enforced heading" do
    instructions = HouseholdContext.instructions(context(), @range, ["lunch", "dinner"])
    enforced = section(instructions, "Household facts (enforced by code):")

    assert enforced =~ "contains_meat"
    assert enforced =~ "allergies"
    refute enforced =~ "budget"
    refute enforced =~ "12345"
    refute enforced =~ "Nutrition Goal"
    refute enforced =~ "1800"
  end

  test "the Nutrition Goal is an unchecked target; the budget is checked by code" do
    instructions = HouseholdContext.instructions(context(), @range, ["dinner"])

    targets =
      section(
        instructions,
        "Targets, not yet validated by code (tell the household they are unchecked):"
      )

    assert targets =~ "Nutrition Goal per standard portion, daily: calories 1800-2200"
    refute targets =~ "budget"
    assert instructions =~ "Never claim that a plan meets the Nutrition Goal"

    assert instructions =~ "Grocery budget (checked by code): 12345 cents (ARS) for the range"
    assert instructions =~ "compares it against the Purchase total"
  end
end
