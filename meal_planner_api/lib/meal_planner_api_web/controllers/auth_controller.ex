defmodule MealPlannerApiWeb.AuthController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Revenuecat
  alias MealPlannerApi.Subscriptions

  def create(conn, params) do
    requested_tier = Subscriptions.normalize_tier(Map.get(params, "subscription_tier", "free"))

    with {:ok, %{user: user, account: account}} <- Accounts.find_or_create_identity(params),
         resolved_tier <- Revenuecat.resolve_tier(account.id, requested_tier),
         user <- Map.put(user, :subscription_tier, resolved_tier),
         account <- Map.put(account, :subscription_tier, resolved_tier),
         {:ok, token, _claims} <-
           Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
             token_type: "access"
           ) do
      subscription =
        account.id
        |> Subscriptions.policy_for_account()
        |> Map.put(:tier, Atom.to_string(resolved_tier))

      json(conn, %{
        access_token: token,
        token_type: "Bearer",
        user: Accounts.serialize_user(user),
        account: Accounts.serialize_account(account),
        subscription: subscription,
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
