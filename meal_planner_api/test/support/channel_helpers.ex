defmodule MealPlannerApiWeb.ChannelHelpers do
  @moduledoc """
  Shared helper functions for channel tests.
  """

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian

  @doc """
  Creates a test user and account, then generates a JWT token.

  Returns `{:ok, user, account, token}`.
  """
  @spec issue_identity_and_token(String.t(), String.t()) ::
          {:ok, MealPlannerApi.Accounts.User.t(), MealPlannerApi.Accounts.Account.t(), String.t()}
  def issue_identity_and_token(user_id, account_id) do
    with {:ok, %{user: user, account: account}} <-
           Accounts.find_or_create_identity(%{"user_id" => user_id, "account_id" => account_id}),
         {:ok, token, _claims} <-
           Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
             token_type: "access"
           ) do
      {:ok, user, account, token}
    end
  end
end
