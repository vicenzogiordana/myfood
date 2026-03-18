defmodule MealPlannerApi.Accounts.User do
  @moduledoc """
  In-memory user model used until persistence is introduced.
  """

  @type account_type :: :individual | :group
  @type subscription_tier :: :free | :premium

  @enforce_keys [:id, :account_id, :account_type]
  defstruct [:id, :account_id, :email, :name, :account_type, subscription_tier: :free]

  @type t :: %__MODULE__{
          id: String.t(),
          account_id: String.t(),
          email: String.t() | nil,
          name: String.t() | nil,
          account_type: account_type(),
          subscription_tier: subscription_tier()
        }
end
