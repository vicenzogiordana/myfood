defmodule MealPlannerApi.PlanningAgent.Optimizer.Unavailable do
  @moduledoc "Optimizer used when none is configured: always a typed failure, never a plan."

  @behaviour MealPlannerApi.PlanningAgent.Optimizer

  @impl true
  def solve(_payload, _opts), do: {:error, :optimizer_unavailable, %{}}
end
