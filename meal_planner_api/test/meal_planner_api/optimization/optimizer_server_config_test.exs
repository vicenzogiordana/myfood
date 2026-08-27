defmodule MealPlannerApi.Optimization.OptimizerServerConfigTest do
  use ExUnit.Case, async: false

  alias MealPlannerApi.Optimization.OptimizerServer

  test "does not start the real optimizer server in test" do
    refute Application.get_env(:meal_planner_api, :start_optimizer_server)
    assert Process.whereis(OptimizerServer) == nil
  end
end
