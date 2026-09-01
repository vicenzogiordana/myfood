defmodule MealPlannerApi.TestSupport.InjectedOptimizer do
  @moduledoc """
  Test double that returns a fixed response from a JSON-decoded string-key
  payload. Used by `PlanningService.run_optimizer/4` tests to prove the
  service calls the injected optimizer module instead of looking up the
  configured one from application env.
  """

  @behaviour MealPlannerApi.Optimization.OptimizerPort

  @impl true
  def select_weekly_menu(_payload), do: {:ok, %{"meals" => [%{"recipe_id" => "injected"}]}}

  @impl true
  def health_check, do: :ok
end
