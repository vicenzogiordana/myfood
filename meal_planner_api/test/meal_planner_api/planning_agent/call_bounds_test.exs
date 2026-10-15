defmodule MealPlannerApi.PlanningAgent.CallBoundsTest do
  @moduledoc "Per-call deadlines and retry budgets (#108)."

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.CallBounds

  @fast %{model: %{timeout_ms: 100, backoff_ms: 1}, read: %{timeout_ms: 100, backoff_ms: 1}}

  defp failing(reason) do
    test = self()

    fn state, _call ->
      send(test, :attempt)
      {:error, reason, state}
    end
  end

  defp attempts(acc \\ 0) do
    receive do
      :attempt -> attempts(acc + 1)
    after
      0 -> acc
    end
  end

  test "defaults follow the contract: model 60 s / 5, solver 120 s / 0, read 30 s / 2" do
    assert %{
             model: %{timeout_ms: 60_000, retries: 5},
             solver: %{timeout_ms: 120_000, retries: 0},
             read: %{timeout_ms: 30_000, retries: 2}
           } = CallBounds.policies()
  end

  test "no retry while the Member is absent" do
    bounds = CallBounds.new(policies: @fast, present?: fn -> false end)

    assert {:error, :provider_unavailable, :state} =
             CallBounds.run(bounds, :model, :state, failing(:provider_unavailable))

    assert attempts() == 1
  end

  test "an unknown reason is never retried" do
    bounds = CallBounds.new(policies: @fast)

    assert {:error, :something_new, _} =
             CallBounds.run(bounds, :read, nil, failing(:something_new))

    assert attempts() == 1
  end

  test "an invalid provider response is deterministic and never retried" do
    bounds = CallBounds.new(policies: @fast)

    refute CallBounds.transient?(:model, :invalid_provider_response)

    assert {:error, :invalid_provider_response, _} =
             CallBounds.run(bounds, :model, nil, failing(:invalid_provider_response))

    assert attempts() == 1
  end

  test "the state reported by a killed attempt is kept" do
    bounds = CallBounds.new(policies: %{solver: %{timeout_ms: 50}})

    hang = fn _state, call ->
      call.report.(:reserved)
      Process.sleep(1_000)
      {:ok, :late, :settled}
    end

    assert {:error, :timeout, :reserved} = CallBounds.run(bounds, :solver, :initial, hang)
  end

  test "an expired global deadline starts no attempt" do
    bounds = CallBounds.new(deadline_at: System.monotonic_time(:millisecond) - 1)

    assert {:error, :deadline_exceeded, :state} =
             CallBounds.run(bounds, :model, :state, failing(:provider_unavailable))

    assert attempts() == 0
  end

  test "each attempt is told its effective deadline" do
    bounds =
      CallBounds.new(
        policies: %{read: %{timeout_ms: 30_000}},
        deadline_at: System.monotonic_time(:millisecond) + 1_000
      )

    assert {:ok, timeout_ms, nil} =
             CallBounds.run(bounds, :read, nil, fn s, call -> {:ok, call.timeout_ms, s} end)

    assert timeout_ms <= 1_000
  end
end
