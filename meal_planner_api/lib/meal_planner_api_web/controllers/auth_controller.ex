defmodule MealPlannerApiWeb.AuthController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Services.RevenuecatService
  alias MealPlannerApi.Services.SubscriptionService

  def social(conn, %{"provider" => provider, "id_token" => id_token} = params) do
    requested_tier =
      SubscriptionService.normalize_tier(Map.get(params, "subscription_tier", "free"))

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
    requested_tier =
      SubscriptionService.normalize_tier(Map.get(params, "subscription_tier", "free"))

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

  # POST /auth/refresh
  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case Guardian.decode_and_verify(refresh_token, %{}, token_type: "refresh") do
      {:ok, %{"sub" => user_id, "account_id" => account_id}} ->
        case load_user_and_account(user_id, account_id) do
          {:ok, user, account} ->
            requested_tier = Map.get(conn.params, "subscription_tier", "free")
            resolved_tier = RevenuecatService.resolve_tier(account.id, requested_tier)
            user = Map.put(user, :subscription_tier, resolved_tier)
            account = Map.put(account, :subscription_tier, resolved_tier)

            with {:ok, new_access_token, _} <-
                   Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
                     token_type: "access"
                   ),
                 {:ok, new_refresh_token, _} <-
                   Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
                     token_type: "refresh"
                   ) do
              json(conn, %{
                access_token: new_access_token,
                refresh_token: new_refresh_token
              })
            else
              _ ->
                conn
                |> put_status(:unauthorized)
                |> json(%{error: "token_refresh_failed"})
            end

          _ ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "invalid_refresh_token"})
        end

      {:error, _reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_refresh_token"})
    end
  end

  def refresh(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_refresh_token"})
  end

  # POST /auth/logout
  def logout(conn, _params) do
    # For now, just acknowledge logout
    # Token invalidation would require denylist or token tracking
    json(conn, %{message: "Logged out successfully"})
  end

  defp load_user_and_account(user_id, account_id) do
    user = MealPlannerApi.Repo.get(MealPlannerApi.Persistence.Accounts.User, user_id)
    account = MealPlannerApi.Repo.get(MealPlannerApi.Persistence.Accounts.Account, account_id)

    if user && account, do: {:ok, user, account}, else: {:error, :not_found}
  end

  defp issue_auth_response(conn, user, account, requested_tier) do
    with resolved_tier <- RevenuecatService.resolve_tier(account.id, requested_tier),
         user <- Map.put(user, :subscription_tier, resolved_tier),
         account <- Map.put(account, :subscription_tier, resolved_tier),
         {:ok, access_token, _access_claims} <-
           Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
             token_type: "access"
           ),
         {:ok, refresh_token, _refresh_claims} <-
           Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
             token_type: "refresh"
           ) do
      subscription =
        account.id
        |> SubscriptionService.policy_for_account()
        |> Map.put(:tier, Atom.to_string(resolved_tier))

      json(conn, %{
        access_token: access_token,
        refresh_token: refresh_token,
        token_type: "Bearer",
        user: Accounts.serialize_user(user),
        account: Accounts.serialize_account(account),
        subscription: subscription,
        websocket: %{
          path: "/socket/websocket",
          params: %{token: access_token}
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
