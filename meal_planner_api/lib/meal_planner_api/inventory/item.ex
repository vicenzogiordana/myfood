defmodule MealPlannerApi.Inventory.Item do
  @moduledoc """
  In-memory inventory ingredient model.
  """

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}
end
