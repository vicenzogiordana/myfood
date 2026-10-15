defmodule MealPlannerApi.PlanningAgent.Optimizer.PortTest do
  @moduledoc """
  Port boundary of the planning agent optimizer: one subprocess per call
  through the existing port runner, typed failures, no fallback plan. Uses a
  Python stand-in that speaks the optimizer's line protocol.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MealPlannerApi.PlanningAgent.ConcurrencyLimiter
  alias MealPlannerApi.PlanningAgent.Optimizer.Port, as: PortOptimizer

  @script Path.expand("../../../support/fixtures/fake_optimizer.py", __DIR__)

  defp payload(mode) do
    %{
      "fake_mode" => mode,
      "days" => ["2026-11-02"],
      "slots" => ["lunch", "dinner"],
      "constraints" => %{},
      "candidates_by_slot" => %{
        "lunch" => [%{"recipe_id" => "r-lunch"}],
        "dinner" => [%{"recipe_id" => "r-dinner"}]
      }
    }
  end

  defp opts(extra \\ []),
    do:
      Keyword.merge(
        [
          python_executable: System.find_executable("python3"),
          script_path: @script,
          max_concurrent_runs: 100
        ],
        extra
      )

  test "returns the optimizer's plan" do
    assert {:ok, %{"meals" => meals}} = PortOptimizer.solve(payload("solve"), opts())

    assert meals == [
             %{"day" => "2026-11-02", "slot" => "lunch", "recipe_id" => "r-lunch"},
             %{"day" => "2026-11-02", "slot" => "dinner", "recipe_id" => "r-dinner"}
           ]
  end

  describe "global concurrency cap" do
    setup do
      name = :"limiter_#{System.unique_integer([:positive])}"
      start_supervised!({ConcurrencyLimiter, name: name})
      %{limiter: name}
    end

    test "a run over the cap is refused before any subprocess starts", %{limiter: limiter} do
      test = self()

      holder =
        spawn(fn ->
          ConcurrencyLimiter.run(limiter, :optimizer_runs, 1, fn ->
            send(test, :holding)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :holding

      notify = fn event -> send(test, {:os_process, event}) end

      assert {:error, :optimizer_busy, %{}} =
               PortOptimizer.solve(
                 payload("solve"),
                 opts(max_concurrent_runs: 1, concurrency_limiter: limiter, on_os_process: notify)
               )

      refute_received {:os_process, _}

      Process.exit(holder, :kill)
      wait_until_free(limiter)

      assert {:ok, %{"meals" => [_, _]}} =
               PortOptimizer.solve(
                 payload("solve"),
                 opts(max_concurrent_runs: 1, concurrency_limiter: limiter)
               )
    end

    test "every finished run frees its slot, failures included", %{limiter: limiter} do
      capped = opts(max_concurrent_runs: 1, concurrency_limiter: limiter)

      assert {:error, :optimizer_crashed, _} = PortOptimizer.solve(payload("crash"), capped)
      assert {:error, :infeasible, _} = PortOptimizer.solve(payload("error"), capped)
      assert {:ok, _} = PortOptimizer.solve(payload("solve"), capped)
      assert ConcurrencyLimiter.in_use(limiter, :optimizer_runs) == 0
    end

    test "an unset or invalid cap refuses as unconfigured without starting a subprocess" do
      for cap <- [nil, 0, "2"] do
        assert {:error, :optimizer_unconfigured, %{}} =
                 PortOptimizer.solve(payload("solve"), opts(max_concurrent_runs: cap))
      end
    end

    test "the cap defaults to the application configuration" do
      assert Application.get_env(:meal_planner_api, PortOptimizer)[:max_concurrent_runs] == nil

      assert {:error, :optimizer_unconfigured, %{}} =
               PortOptimizer.solve(payload("solve"), Keyword.delete(opts(), :max_concurrent_runs))
    end
  end

  defp wait_until_free(limiter) do
    if ConcurrencyLimiter.in_use(limiter, :optimizer_runs) > 0 do
      Process.sleep(5)
      wait_until_free(limiter)
    end
  end

  test "skips non-protocol output lines" do
    assert {:ok, %{"meals" => [_, _]}} = PortOptimizer.solve(payload("noisy"), opts())
  end

  test "an optimizer error is a typed error with its details" do
    assert {:error, :infeasible, %{"causes" => ["no_recipe_for_slot"]}} =
             PortOptimizer.solve(payload("error"), opts())
  end

  test "a timeout is reported as a timeout, never as a plan" do
    started = System.monotonic_time(:millisecond)

    assert {:error, :optimizer_timeout, %{}} =
             PortOptimizer.solve(payload("hang"), opts(timeout_ms: 300))

    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  test "a crashed optimizer process is reported as crashed" do
    assert {:error, :optimizer_crashed, %{"exit_status" => 3}} =
             PortOptimizer.solve(payload("crash"), opts())
  end

  defmodule ObservedRunner do
    @moduledoc false
    # Opens the real port and reports its OS pid to the observing test.
    def open_port(opts) do
      {:ok, port} = MealPlannerApi.Optimization.OptimizerPortRunner.open_port(opts)
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      send(:persistent_term.get({__MODULE__, :observer}), {:optimizer_os_pid, os_pid})
      {:ok, port}
    end
  end

  defp os_alive?(os_pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  defp eventually_dead?(os_pid, attempts \\ 40) do
    cond do
      not os_alive?(os_pid) ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually_dead?(os_pid, attempts - 1)
    end
  end

  test "a brutally killed caller does not orphan the optimizer process" do
    :persistent_term.put({ObservedRunner, :observer}, self())
    on_exit(fn -> :persistent_term.erase({ObservedRunner, :observer}) end)

    task =
      Task.async(fn ->
        PortOptimizer.solve(
          payload("hang"),
          opts(port_runner: ObservedRunner, timeout_ms: 30_000)
        )
      end)

    assert_receive {:optimizer_os_pid, os_pid}, 5_000
    Process.sleep(200)
    assert os_alive?(os_pid)

    Task.shutdown(task, :brutal_kill)

    assert eventually_dead?(os_pid)
  end

  test "reports the OS process to its owner when it starts and when the call releases it" do
    test_pid = self()
    notify = fn event -> send(test_pid, {:os_process, event}) end

    assert {:ok, _} = PortOptimizer.solve(payload("solve"), opts(on_os_process: notify))

    assert_received {:os_process, {:started, os_pid}}
    assert_received {:os_process, {:closed, ^os_pid}}
  end

  test "a missing executable is reported as unavailable" do
    assert {:error, :optimizer_unavailable, %{}} =
             PortOptimizer.solve(payload("solve"), opts(python_executable: "/nonexistent/python"))
  end

  defmodule ClosedPortRunner do
    @moduledoc false
    # A subprocess that is already gone when the first frame is written.
    def open_port(_opts) do
      port = Port.open({:spawn_executable, System.find_executable("true")}, [:binary])
      Port.close(port)
      {:ok, port}
    end
  end

  test "a subprocess gone before the handshake is reported as crashed" do
    assert {:error, :optimizer_crashed, %{}} =
             PortOptimizer.solve(payload("solve"), opts(port_runner: ClosedPortRunner))
  end
end
