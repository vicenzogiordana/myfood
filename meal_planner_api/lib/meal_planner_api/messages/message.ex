defmodule MealPlannerApi.Messages.Message do
  @moduledoc """
  Chat message DTO used for parsing and transporting conversation history.
  """

  @enforce_keys [:role, :content]
  defstruct [:role, :content]

  @type role :: :user | :assistant | :system

  @type t :: %__MODULE__{
          role: role(),
          content: String.t()
        }
end
