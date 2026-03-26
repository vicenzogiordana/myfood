defmodule MealPlannerApi.PlanningCaptureOptimizerClient do
  @moduledoc false

  @behaviour MealPlannerApi.Planning.OptimizerClient

  @impl true
  def select_weekly_menu(payload) when is_map(payload) do
    capture_pid = Application.get_env(:meal_planner_api, :planning_optimizer_capture_pid)

    if is_pid(capture_pid) do
      send(capture_pid, {:optimizer_payload, payload})
    end

    MealPlannerApi.Planning.MockOptimizerClient.select_weekly_menu(payload)
  end
end
