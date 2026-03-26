defmodule MealPlannerApi.Planning.OptimizerClient do
  @moduledoc """
  Behaviour for weekly menu optimization backends.
  """

  @callback select_weekly_menu(map()) :: {:ok, map()} | {:error, term()}
end
