defmodule MealPlannerApiWeb.Controllers.AccountScopeHelpers do
  @moduledoc """
  Shared helpers for Phase A membership-aware controllers (PR 3a —
  `MembershipController`, `InviteController`, `AccountLifecycleController`).

  Kept as a plain module (not a plug) — these are controller-layer
  conveniences, not pipeline steps. Extracted to avoid duplicating
  `load_account/1`, membership serialization, and the "mint access_v2
  + refresh, render the standard auth payload" pattern across all three
  new controllers (design §6).
  """

  import Phoenix.Controller, only: [json: 2]

  alias MealPlannerApi.Accounts, as: AccountsContext
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.SubscriptionService
  alias Plug.Conn

  @doc """
  Loads an `Account` by its (string) id. Returns `{:error,
  :account_not_found}` for a malformed id or a missing row — callers
  MUST render this as `404 account_not_found` (no existence leak, per
  `specs/invite-and-accept.md` §"Membership roster").
  """
  @spec load_account(String.t()) :: {:ok, Account.t()} | {:error, :account_not_found}
  def load_account(account_id) when is_binary(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, uuid} ->
        case Repo.get(Account, uuid) do
          %Account{} = account -> {:ok, account}
          nil -> {:error, :account_not_found}
        end

      :error ->
        {:error, :account_not_found}
    end
  end

  def load_account(_), do: {:error, :account_not_found}

  @doc """
  Serializes an `AccountMembership` for API responses (design §6.2/§6.5
  "membership" payload key). `id` is `nil` for a synthesized legacy
  membership (Q1) — callers must not assume it is always present.
  """
  @spec serialize_membership(AccountMembership.t()) :: map()
  def serialize_membership(%{} = membership) do
    %{
      id: membership.id && to_string(membership.id),
      account_id: to_string(membership.account_id),
      role: Atom.to_string(membership.role),
      status: Atom.to_string(membership.status),
      joined_at: membership.joined_at
    }
  end

  @doc """
  Mints `access_token` + `refresh_token` from a full claim map and
  renders the standard auth payload (`access_token`, `refresh_token`,
  `user`, `account`, `membership`, `subscription`, `websocket`).

  Delegates the actual minting to `mint_token_pair/2` (post-review fix
  pass item 4 — the single canonical implementation, also used by
  `AuthController`).
  """
  @spec render_membership_auth_response(
          Conn.t(),
          map(),
          Account.t(),
          AccountMembership.t(),
          map()
        ) :: Conn.t()
  def render_membership_auth_response(conn, user, account, membership, claims) do
    with {:ok, access_token, refresh_token} <- mint_token_pair(user, claims) do
      subscription = SubscriptionService.policy_for_account(account.id)

      json(conn, %{
        access_token: access_token,
        refresh_token: refresh_token,
        token_type: "Bearer",
        user: AccountsContext.serialize_user(user),
        account: AccountsContext.serialize_account(account),
        membership: serialize_membership(membership),
        subscription: subscription,
        websocket: %{
          path: "/socket/websocket",
          params: %{token: access_token}
        }
      })
    end
  end

  @doc """
  Mints `access_token` + `refresh_token` from a single claim map. The
  refresh token strips `"typ"` from the claim map before minting so
  `Guardian.encode_and_sign/3`'s `token_type: "refresh"` option can set
  it — a claim map carrying an explicit `"typ"` (e.g. `access_v2`'s
  `AccountsMembership.claims_for/2` output) is otherwise NOT overridden
  by Guardian's `set_type/3` (the same class of bug fixed in PR 2b for
  `Accounts.claims_for/2` — see `accounts.ex`). This is the single
  canonical implementation of "mint access + mint refresh with typ
  stripped, else :error" — post-review fix pass item 4 consolidates 3
  duplicate reimplementations (`AuthController.issue_auth_response/6`'s
  two clauses + this module's old inline version) down to this one.
  """
  @spec mint_token_pair(map(), map()) ::
          {:ok, String.t(), String.t()} | {:error, :token_refresh_failed}
  def mint_token_pair(user, claims) do
    with {:ok, access_token, _access_claims} <-
           Guardian.encode_and_sign(user, claims, token_type: "access"),
         {:ok, refresh_token, _refresh_claims} <-
           Guardian.encode_and_sign(user, Map.delete(claims, "typ"), token_type: "refresh") do
      {:ok, access_token, refresh_token}
    else
      _ -> {:error, :token_refresh_failed}
    end
  end
end
