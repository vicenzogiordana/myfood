defmodule MealPlannerApiWeb.AuthController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Revenuecat
  alias MealPlannerApi.Subscriptions

  def social(conn, %{"provider" => provider, "id_token" => id_token} = params) do
    requested_tier = Subscriptions.normalize_tier(Map.get(params, "subscription_tier", "free"))

    with {:ok, identity} <- social_verifier().verify(provider, id_token, social_opts()),
         identity_params <- social_identity_to_params(identity, params),
         {:ok, %{user: user, account: account}} <-
           Accounts.find_or_create_identity(identity_params) do
      issue_auth_response(conn, user, account, requested_tier)
    else
      {:error, reason}
      when reason in [
             :unsupported_provider,
             :invalid_social_token,
             :invalid_issuer,
             :invalid_audience,
             :token_expired,
             :email_not_verified,
             :facebook_not_configured,
             :social_provider_unavailable
           ] ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: Atom.to_string(reason)})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "unable_to_issue_token"})
    end
  end

  def social(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_social_payload"})
  end

  def password(conn, params) when is_map(params) do
    requested_tier = Subscriptions.normalize_tier(Map.get(params, "subscription_tier", "free"))

    result =
      case Map.get(params, "mode", "login") do
        "register" -> Accounts.register_with_password(params)
        "login" -> Accounts.authenticate_with_password(params)
        _ -> {:error, :invalid_auth_mode}
      end

    case result do
      {:ok, %{user: user, account: account}} ->
        issue_auth_response(conn, user, account, requested_tier)

      {:error, reason}
      when reason in [
             :invalid_email,
             :invalid_password,
             :password_too_short,
             :invalid_auth_mode
           ] ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: Atom.to_string(reason)})

      {:error, reason}
      when reason in [
             :invalid_credentials,
             :email_already_registered
           ] ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: Atom.to_string(reason)})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "unable_to_issue_token"})
    end
  end

  defp issue_auth_response(conn, user, account, requested_tier) do
    with resolved_tier <- Revenuecat.resolve_tier(account.id, requested_tier),
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
    end
  end

  defp social_identity_to_params(identity, params) do
    provider = Map.get(identity, :provider)
    provider_user_id = Map.get(identity, :provider_user_id)
    stable_identity = "social:" <> provider <> ":" <> provider_user_id

    %{
      "user_id" => stable_identity,
      "account_id" => stable_identity,
      "account_type" => Map.get(params, "account_type", "individual"),
      "email" => Map.get(identity, :email),
      "name" => Map.get(identity, :name)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp social_verifier,
    do:
      Application.get_env(:meal_planner_api, :social_verifier, MealPlannerApi.Auth.SocialVerifier)

  defp social_opts do
    [
      google_client_ids: Application.get_env(:meal_planner_api, :google_oauth_client_ids, []),
      apple_client_ids: Application.get_env(:meal_planner_api, :apple_oauth_client_ids, []),
      google_tokeninfo_url:
        Application.get_env(
          :meal_planner_api,
          :google_tokeninfo_url,
          "https://oauth2.googleapis.com/tokeninfo"
        ),
      apple_jwks_url:
        Application.get_env(
          :meal_planner_api,
          :apple_jwks_url,
          "https://appleid.apple.com/auth/keys"
        ),
      facebook_app_id: Application.get_env(:meal_planner_api, :facebook_app_id),
      facebook_app_secret: Application.get_env(:meal_planner_api, :facebook_app_secret),
      facebook_graph_url:
        Application.get_env(
          :meal_planner_api,
          :facebook_graph_url,
          "https://graph.facebook.com"
        )
    ]
  end
end
