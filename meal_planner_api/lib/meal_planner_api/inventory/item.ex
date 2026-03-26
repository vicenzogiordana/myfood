defmodule MealPlannerApi.Inventory.Item do
  @moduledoc """
  Lightweight inventory item DTO used by context-level helpers.

  Persistent inventory rows live in `MealPlannerApi.Persistence.Inventory.InventoryItem`.
  """

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}
end
