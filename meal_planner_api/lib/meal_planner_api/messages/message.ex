defmodule MealPlannerApi.Messages.Message do
  @moduledoc """
  In-memory chat message representation.
  """

  @enforce_keys [:role, :content]
  defstruct [:role, :content]

  @type role :: :user | :assistant | :system

  @type t :: %__MODULE__{
          role: role(),
          content: String.t()
        }
end
