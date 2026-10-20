defmodule MealPlannerApi.PlanningAgent.AllowanceTest do
  @moduledoc "Execution allowance of a Planning Session (#108, #154)."

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.Allowance

  defp iterate(allowance, times) do
    Enum.reduce(1..times, allowance, fn _, acc ->
      {:ok, acc} = Allowance.start_iteration(acc)
      acc
    end)
  end

  test "defaults: 15 model calls per Member message, 60 per Planning Session" do
    allowance = Allowance.new()

    assert allowance.max_iterations == 15
    assert allowance.max_session_iterations == 60
  end

  test "the iteration limit of a message holds until the Member authorizes more" do
    allowance = 2 |> Allowance.new() |> Allowance.start_message() |> iterate(2)

    assert {:limit, "iterations"} = Allowance.start_iteration(allowance)

    allowance = Allowance.authorize(allowance, "iterations")
    allowance = iterate(allowance, 2)
    assert {:limit, "iterations"} = Allowance.start_iteration(allowance)
  end

  test "every Member message gets its own iterations" do
    allowance = 15 |> Allowance.new() |> Allowance.start_message() |> iterate(15)
    assert {:limit, "iterations"} = Allowance.start_iteration(allowance)

    allowance = allowance |> Allowance.start_message() |> iterate(15)
    assert allowance.iterations == 30
    assert {:limit, "iterations"} = Allowance.start_iteration(allowance)
  end

  test "the session ceiling ends the Planning Session's allowance, authorized or not" do
    allowance =
      Enum.reduce(1..4, Allowance.new(15, max_session_iterations: 60), fn _, acc ->
        acc |> Allowance.start_message() |> iterate(15)
      end)

    assert allowance.iterations == 60

    assert {:exhausted, "session_iterations"} =
             allowance |> Allowance.start_message() |> Allowance.start_iteration()

    assert {:exhausted, "session_iterations"} =
             allowance |> Allowance.authorize("iterations") |> Allowance.start_iteration()
  end

  test "a refunded iteration (a call refused before the provider) is not counted" do
    allowance = 2 |> Allowance.new(max_session_iterations: 2) |> Allowance.start_message()

    allowance = allowance |> iterate(1) |> Allowance.refund_iteration()
    assert allowance.iterations == 0

    allowance = iterate(allowance, 2)
    assert {:exhausted, "session_iterations"} = Allowance.start_iteration(allowance)
  end

  test "a restored allowance from an older snapshot gains the new counters" do
    old = %{
      __struct__: Allowance,
      max_iterations: 10,
      iteration_limit: 10,
      iterations: 4,
      max_no_progress: 3,
      no_progress: 1,
      evidence: MapSet.new()
    }

    restored = Allowance.restore(old, Allowance.new(15))

    assert restored.iterations == 4
    assert restored.no_progress == 1
    assert restored.max_iterations == 15
    assert restored.max_session_iterations == 60
    assert {:ok, _} = restored |> Allowance.start_message() |> Allowance.start_iteration()
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
