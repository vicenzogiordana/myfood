defmodule MealPlannerApi.PlanningAgent.ConcurrencyLimiterTest do
  @moduledoc """
  Global concurrency slots of the planning agent (issue #118): at most
  `limit` holders of a key at a time, and a slot always comes back, whether
  its holder finishes, raises or is killed.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.ConcurrencyLimiter

  setup do
    name = :"limiter_#{System.unique_integer([:positive])}"
    start_supervised!({ConcurrencyLimiter, name: name})
    %{limiter: name}
  end

  # A process holding one slot of `key` until it is told to finish.
  defp hold!(limiter, key, limit) do
    test = self()

    pid =
      spawn(fn ->
        ConcurrencyLimiter.run(limiter, key, limit, fn ->
          send(test, {:holding, self()})
          receive(do: (:finish -> :ok))
        end)

        send(test, {:finished, self()})
      end)

    assert_receive {:holding, ^pid}
    pid
  end

  test "runs the function while a slot is free", %{limiter: limiter} do
    assert {:ok, :done} = ConcurrencyLimiter.run(limiter, :provider_calls, 1, fn -> :done end)
    assert ConcurrencyLimiter.in_use(limiter, :provider_calls) == 0
  end

  test "refuses without running the function once the limit is reached", %{limiter: limiter} do
    hold!(limiter, :provider_calls, 2)
    hold!(limiter, :provider_calls, 2)

    assert {:error, :at_capacity} =
             ConcurrencyLimiter.run(limiter, :provider_calls, 2, fn -> flunk("ran") end)

    assert ConcurrencyLimiter.in_use(limiter, :provider_calls) == 2
  end

  test "keys are limited independently", %{limiter: limiter} do
    hold!(limiter, :provider_calls, 1)

    assert {:ok, :solved} = ConcurrencyLimiter.run(limiter, :optimizer_runs, 1, fn -> :solved end)
  end

  test "a finished holder frees its slot", %{limiter: limiter} do
    holder = hold!(limiter, :provider_calls, 1)
    send(holder, :finish)
    assert_receive {:finished, ^holder}

    assert {:ok, :again} = ConcurrencyLimiter.run(limiter, :provider_calls, 1, fn -> :again end)
  end

  test "a holder that raises frees its slot", %{limiter: limiter} do
    assert_raise RuntimeError, fn ->
      ConcurrencyLimiter.run(limiter, :provider_calls, 1, fn -> raise "boom" end)
    end

    assert {:ok, :again} = ConcurrencyLimiter.run(limiter, :provider_calls, 1, fn -> :again end)
  end

  test "a holder killed with :brutal_kill frees its slot", %{limiter: limiter} do
    holder = hold!(limiter, :provider_calls, 1)
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

    assert {:ok, :again} = ConcurrencyLimiter.run(limiter, :provider_calls, 1, fn -> :again end)
    assert ConcurrencyLimiter.in_use(limiter, :provider_calls) == 0
  end

  test "an invalid limit refuses as unconfigured", %{limiter: limiter} do
    for limit <- [nil, 0, -1, "2"] do
      assert {:error, :unconfigured} =
               ConcurrencyLimiter.run(limiter, :provider_calls, limit, fn -> flunk("ran") end)
    end
  end
end
