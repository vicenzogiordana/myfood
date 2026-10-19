defmodule MealPlannerApi.PlanningAgent.Battery.FailingRecipeSearch do
  @moduledoc """
  Recipe search of the battery's repeated-tool-failures task (issue #109):
  every call fails, as a search backend that is down would.
  """

  @doc "Always `{:error, :search_failed}`."
  def search(_household, _filters, _opts), do: {:error, :search_failed}
end
