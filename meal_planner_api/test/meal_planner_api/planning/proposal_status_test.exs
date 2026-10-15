defmodule MealPlannerApi.Planning.ProposalStatusTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Planning.ProposalStatus

  @calorie_deviation %{
    goal: :calories,
    priority: 2,
    day: ~D[2026-09-07],
    direction: :below_min,
    bound: 1_000,
    actual: 400,
    amount: 600
  }

  test "a Proposal meeting every goal is valid" do
    assert ProposalStatus.classify([], []) == :valid
  end

  test "a Proposal with Deviations requires approval" do
    assert ProposalStatus.classify([], [@calorie_deviation]) == :requires_approval
  end

  test "a Proposal with violations is invalid even when it also has Deviations" do
    violation = %{"kind" => "restriction", "date" => "2026-09-07", "slot" => "lunch"}

    assert ProposalStatus.classify([violation], [@calorie_deviation]) == :invalid
  end
end
