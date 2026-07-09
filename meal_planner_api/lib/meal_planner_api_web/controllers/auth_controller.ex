defmodule MealPlannerApiWeb.AuthController do
  use MealPlannerApiWeb, :controller

  require Logger

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Services.RevenuecatService
  alias MealPlannerApi.Services.SubscriptionService
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

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
      {:ok, %{user: user, account: account, membership: membership}} ->
        issue_auth_response(
          conn,
          user,
          account,
          requested_tier,
          issuance_typ(membership),
          membership
        )

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
  #
  # Phase A — Tenancy Refactor (PR 3a task 3.8): re-issues WHATEVER `typ`
  # the incoming refresh token carried — `access` or `access_v2` — no
  # silent re-scoping in either direction, independent of the current
  # `MEAL_PLANNER_TENANCY_V2` flag value at refresh time. The flag only
  # controls issuance on `password/2`; `refresh/2` never consults it.
  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case Guardian.decode_and_verify(refresh_token, %{}, token_type: "refresh") do
      {:ok, claims} ->
        case reissue_from_refresh_claims(conn, claims) do
          {:ok, new_access_token, new_refresh_token} ->
            json(conn, %{
              access_token: new_access_token,
              refresh_token: new_refresh_token
            })

          {:error, :token_refresh_failed} ->
            Logger.warning("refresh token rotation failed reason=token_refresh_failed")

            conn
            |> put_status(:unauthorized)
            |> json(%{error: "token_refresh_failed"})

          {:error, reason} ->
            Logger.warning("refresh token rotation failed reason=#{inspect(reason)}")

            conn
            |> put_status(:unauthorized)
            |> json(%{error: "invalid_refresh_token"})
        end

      {:error, reason} ->
        Logger.warning("refresh token decode_and_verify failed reason=#{inspect(reason)}")

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

  # Phase A — Tenancy Refactor (PR 3a task 3.8): `password/2` (register +
  # login modes) picks `:access_v2` only when the flag is on AND a real
  # `AccountMembership` row came back from `Accounts.register_with_password/1`
  # / `Accounts.authenticate_with_password/1`. Without a membership row
  # (e.g. a legacy User with no matching membership on this Account yet)
  # falls back to `:access` rather than crashing `AccountsMembership.claims_for/2`.
  defp issuance_typ(%AccountMembership{}) do
    if tenancy_v2_only?(), do: :access_v2, else: :access
  end

  defp issuance_typ(_membership), do: :access

  defp tenancy_v2_only? do
    Application.get_env(:meal_planner_api, :tenancy_v2_only, false)
  end

  # `issue_auth_response/6` — the `typ:`-and-`membership` arguments control
  # which claim builder mints the token pair. `social/2` still calls the
  # 4-arg form (defaults to `:access`, `nil` membership) — social auth is
  # out of Phase A scope (design.md does not mention it). Both clauses
  # delegate the actual mint to `AccountScopeHelpers.mint_token_pair/2`
  # (post-review fix pass item 4 — single canonical implementation).
  defp issue_auth_response(conn, user, account, requested_tier, typ \\ :access, membership \\ nil)

  defp issue_auth_response(
         conn,
         user,
         account,
         requested_tier,
         :access_v2,
         %AccountMembership{} = membership
       ) do
    with resolved_tier <- RevenuecatService.resolve_tier(account.id, requested_tier),
         user <- Map.put(user, :subscription_tier, resolved_tier),
         account <- Map.put(account, :subscription_tier, resolved_tier),
         claims <- AccountsMembership.claims_for(user, membership),
         {:ok, access_token, refresh_token} <- mint_token_pair(user, claims) do
      render_auth_json(conn, user, account, resolved_tier, access_token, refresh_token)
    end
  end

  defp issue_auth_response(conn, user, account, requested_tier, _typ, _membership) do
    with resolved_tier <- RevenuecatService.resolve_tier(account.id, requested_tier),
         user <- Map.put(user, :subscription_tier, resolved_tier),
         account <- Map.put(account, :subscription_tier, resolved_tier),
         claims <- Accounts.claims_for(user, account),
         {:ok, access_token, refresh_token} <- mint_token_pair(user, claims) do
      render_auth_json(conn, user, account, resolved_tier, access_token, refresh_token)
    end
  end

  defp render_auth_json(conn, user, account, resolved_tier, access_token, refresh_token) do
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

  # Phase A — Tenancy Refactor (PR 3a task 3.8): dispatches on the
  # INCOMING refresh token's claims to decide which claim builder
  # re-mints the pair — `membership_id` present means the original
  # access token was `access_v2`; its absence means legacy `access`.
  # This is independent of the CURRENT `tenancy_v2_only?/0` flag value —
  # that is what "no silent re-scoping on refresh" (design §3, §5.2)
  # means in practice.
  defp reissue_from_refresh_claims(_conn, %{"sub" => user_id, "membership_id" => membership_id})
       when is_binary(membership_id) and membership_id != "" do
    with %MealPlannerApi.Persistence.Accounts.User{} = user <-
           MealPlannerApi.Repo.get(MealPlannerApi.Persistence.Accounts.User, user_id),
         {:ok, uuid} <- Ecto.UUID.cast(membership_id),
         %AccountMembership{} = membership <- MealPlannerApi.Repo.get(AccountMembership, uuid) do
      claims = AccountsMembership.claims_for(user, membership)
      mint_token_pair(user, claims)
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  defp reissue_from_refresh_claims(conn, %{"sub" => user_id, "account_id" => account_id}) do
    case load_user_and_account(user_id, account_id) do
      {:ok, user, account} ->
        requested_tier =
          SubscriptionService.normalize_tier(Map.get(conn.params, "subscription_tier", "free"))

        resolved_tier = RevenuecatService.resolve_tier(account.id, requested_tier)
        user = Map.put(user, :subscription_tier, resolved_tier)
        account = Map.put(account, :subscription_tier, resolved_tier)

        mint_token_pair(user, Accounts.claims_for(user, account))

      _ ->
        {:error, :invalid_refresh_token}
    end
  end

  defp reissue_from_refresh_claims(_conn, _claims), do: {:error, :invalid_refresh_token}

  # Post-review fix pass item 4: delegates to the single canonical
  # implementation in `AccountScopeHelpers`, shared with
  # `render_membership_auth_response/5`, instead of reimplementing
  # "mint access + mint refresh with typ stripped, else :error" here.
  defp mint_token_pair(user, claims), do: AccountScopeHelpers.mint_token_pair(user, claims)

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
