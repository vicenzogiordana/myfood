defmodule MealPlannerApi.PlanningCaptureOptimizerClient do
  @moduledoc """
  Test double that captures the optimizer payload and delegates to OptimizerMock.
  Used by planning tests that need to inspect the optimizer payload.
  """

  @behaviour MealPlannerApi.Optimization.OptimizerPort

  @impl true
  def select_weekly_menu(payload) when is_map(payload) do
    capture_pid = Application.get_env(:meal_planner_api, :planning_optimizer_capture_pid)

    if is_pid(capture_pid) do
      send(capture_pid, {:optimizer_payload, deep_stringify_keys(payload)})
    end

    MealPlannerApi.Optimization.OptimizerMock.select_weekly_menu(payload)
  end

  defp deep_stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), deep_stringify_keys(v)} end)
    |> Map.new()
  end

  defp deep_stringify_keys(list) when is_list(list), do: Enum.map(list, &deep_stringify_keys/1)
  defp deep_stringify_keys(other), do: other

  @impl true
  def health_check, do: :ok
end
