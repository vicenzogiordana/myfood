defmodule MealPlannerApiWeb.AuthController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Subscriptions

  def create(conn, params) do
    with {:ok, %{user: user, account: account}} <- Accounts.issue_mock_identity(params),
         {:ok, token, _claims} <-
           Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
             token_type: "access"
           ) do
      json(conn, %{
        access_token: token,
        token_type: "Bearer",
        user: Accounts.serialize_user(user),
        account: Accounts.serialize_account(account),
        subscription: Subscriptions.policy_for(user.subscription_tier),
        websocket: %{
          path: "/socket/websocket",
          params: %{token: token}
        }
      })
    else
      _error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "unable_to_issue_token"})
    end
  end
end
