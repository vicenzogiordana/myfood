defmodule MealPlannerApi.Accounts.Account do
  @moduledoc """
  In-memory account aggregate.
  """

  @type account_type :: :individual | :group

  @enforce_keys [:id, :type, :owner_id]
  defstruct [:id, :type, :owner_id, linked_user_ids: [], subscription_tier: :free]

  @type t :: %__MODULE__{
          id: String.t(),
          type: account_type(),
          owner_id: String.t(),
          linked_user_ids: [String.t()],
          subscription_tier: :free | :premium
        }
end
