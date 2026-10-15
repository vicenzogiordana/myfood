defmodule MealPlannerApi.PlanningAgent.Optimizer do
  @moduledoc """
  Optimizer port used by the `run_optimizer` tool (spec #93).

  The payload is the JSON-shaped problem the Python OR-Tools optimizer reads
  (`"days"`, `"slots"`, `"constraints"`, `"candidates_by_slot"`). A success
  carries `"meals"` with `"day"`, `"slot"` and `"recipe_id"` per meal.
  Failures are typed and returned as-is: there is never a fallback plan.
  """

  @type payload :: %{required(String.t()) => term()}
  @type result ::
          {:ok, %{required(String.t()) => term()}} | {:error, atom(), map()}

  @callback solve(payload(), keyword()) :: result()
end
