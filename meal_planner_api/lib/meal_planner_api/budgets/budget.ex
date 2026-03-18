defmodule MealPlannerApi.Budgets.Budget do
  @moduledoc """
  In-memory account budget object.
  """

  @enforce_keys [:account_id, :weekly_limit_cents, :currency]
  defstruct [:account_id, :weekly_limit_cents, :currency]

  @type t :: %__MODULE__{
          account_id: String.t(),
          weekly_limit_cents: pos_integer(),
          currency: String.t()
        }
end
