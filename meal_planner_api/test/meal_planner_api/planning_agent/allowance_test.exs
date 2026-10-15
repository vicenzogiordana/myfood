defmodule MealPlannerApi.PlanningAgent.AllowanceTest do
  @moduledoc "Session-level execution allowance (#108)."

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.Allowance

  defp iterate(allowance, times) do
    Enum.reduce(1..times, allowance, fn _, acc ->
      {:ok, acc} = Allowance.start_iteration(acc)
      acc
    end)
  end

  test "the iteration limit holds until the Member authorizes more" do
    allowance = 2 |> Allowance.new() |> iterate(2)

    assert {:limit, "iterations"} = Allowance.start_iteration(allowance)

    allowance = Allowance.authorize(allowance, "iterations")
    allowance = iterate(allowance, 2)
    assert {:limit, "iterations"} = Allowance.start_iteration(allowance)
  end

  test "new evidence resets the no-progress streak; repeated evidence does not" do
    allowance = Allowance.new(10)

    assert {:ok, allowance} = Allowance.record_attempt(allowance, [:a])
    assert {:ok, allowance} = Allowance.record_attempt(allowance, [:a])
    assert {:ok, allowance} = Allowance.record_attempt(allowance, [])
    assert {:ok, allowance} = Allowance.record_attempt(allowance, [:b])
    assert allowance.no_progress == 0

    assert {:ok, allowance} = Allowance.record_attempt(allowance, [:a, :b])
    assert {:ok, allowance} = Allowance.record_attempt(allowance, [:b])
    assert {:limit, "no_progress", allowance} = Allowance.record_attempt(allowance, [])

    assert %{no_progress: 0} = Allowance.authorize(allowance, "no_progress")
  end
end
