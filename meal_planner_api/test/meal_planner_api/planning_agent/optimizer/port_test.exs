defmodule MealPlannerApi.PlanningAgent.Optimizer.PortTest do
  @moduledoc """
  Port boundary of the planning agent optimizer: one subprocess per call
  through the existing port runner, typed failures, no fallback plan. Uses a
  Python stand-in that speaks the optimizer's line protocol.
  """

  use ExUnit.Case, async: true

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
        [python_executable: System.find_executable("python3"), script_path: @script],
        extra
      )

  test "returns the optimizer's plan" do
    assert {:ok, %{"meals" => meals}} = PortOptimizer.solve(payload("solve"), opts())

    assert meals == [
             %{"day" => "2026-11-02", "slot" => "lunch", "recipe_id" => "r-lunch"},
             %{"day" => "2026-11-02", "slot" => "dinner", "recipe_id" => "r-dinner"}
           ]
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

  test "a missing executable is reported as unavailable" do
    assert {:error, :optimizer_unavailable, %{}} =
             PortOptimizer.solve(payload("solve"), opts(python_executable: "/nonexistent/python"))
  end
end
