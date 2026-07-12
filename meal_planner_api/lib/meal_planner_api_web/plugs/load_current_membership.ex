defmodule MealPlannerApiWeb.Plugs.LoadCurrentMembership do
  @moduledoc """
  Phoenix plug that populates `conn.assigns.current_membership` from the
  decoded JWT claims (Phase A — Tenancy Refactor, PR 1 task 1.10).

  Per `design.md` §4.2:

    * When the JWT is `typ: "access_v2"` the plug loads the
      `AccountMembership` row identified by `claims["membership_id"]`,
      preload `:account`. Missing/invalid → halt with
      `401 unauthorized, %{error: "membership_id_required"}`.

    * When the JWT is `typ: "access"` (legacy fallback) the plug loads
      the real, `:active` `AccountMembership` row for
      `(current_user.id, current_user.account_id)`. If no such row
      exists — e.g. the member was removed, or never was one — the
      request is refused with `401 membership_id_required`, exactly
      like the `access_v2` no-membership case. It no longer fabricates
      an in-memory `:active` struct (see the BLOCKER fix note on
      `synthesize_legacy_membership/2` below).

  The plug is read-only on the conn — it never mutates the User record.
  """

  require Logger

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case membership_for_conn(conn) do
      {:ok, membership} ->
        Plug.Conn.assign(conn, :current_membership, membership)

      {:error, :membership_id_required} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":"membership_id_required"}))
        |> Plug.Conn.halt()
    end
  end

  @doc """
  Looks up the membership for a Phoenix `%Plug.Conn{}`. Exposed for
  callers that want to inspect the assignment directly (e.g. controllers
  that need both the User and the membership).
  """
  @spec membership_for_conn(Plug.Conn.t()) ::
          {:ok, AccountMembership.t()} | {:error, :membership_id_required}
  def membership_for_conn(conn) do
    claims =
      conn.private[:guardian_default_claims] ||
        conn.assigns[:guardian_default_claims] || %{}

    typ = Map.get(claims, "typ", "access")

    current_user =
      try do
        Guardian.Plug.current_resource(conn) || conn.assigns[:default]
      rescue
        _ -> conn.assigns[:default]
      end

    case typ do
      "access_v2" ->
        load_access_v2_membership(claims)

      "access" ->
        synthesize_legacy_membership(current_user, claims)

      _ ->
        # Unknown typ. Same as the no-membership case — Guardian should
        # have rejected this in the pipeline, but if it slipped through
        # we refuse rather than silently synthesize.
        {:error, :membership_id_required}
    end
  end

  defp load_access_v2_membership(claims) do
    case Map.get(claims, "membership_id") do
      nil ->
        {:error, :membership_id_required}

      "" ->
        {:error, :membership_id_required}

      membership_id ->
        case load_membership_by_id(membership_id) do
          %AccountMembership{} = membership -> {:ok, membership}
          _ -> {:error, :membership_id_required}
        end
    end
  end

  defp load_membership_by_id(membership_id) do
    case Ecto.UUID.cast(membership_id) do
      {:ok, uuid} ->
        uuid
        |> AccountMembershipByIdQuery.call()
        |> Repo.one()

      _ ->
        nil
    end
  end

  # Post-PR-3b review — BLOCKER fix (legacy membership synthesis).
  #
  # This used to fabricate an in-memory `%AccountMembership{status:
  # :active}` straight from `user.account_id`, with NO database lookup at
  # all. `AccountsMembership.remove_member/3` and `.leave/2` hard-delete
  # the real `AccountMembership` row without ever clearing
  # `user.account_id`, and Guardian's `access` tokens carry a 4-week TTL
  # with no server-side revocation — so a removed member's stale legacy
  # token retained full access for up to 4 weeks. We now REQUIRE a real,
  # `:active` `AccountMembership` row for `(user_id, account_id)` before
  # granting access. PR 1's backfill migration (task 1.4), PR 2b's atomic
  # `register_with_password/1` (task 2.10), and `Accounts.
  # find_or_create_identity/1`'s membership upsert (this fix) guarantee
  # every currently-valid legacy member has such a row — so "no active
  # row found" now correctly means "no longer an active member" (removed,
  # or never was), not "trust the token's claim".
  defp synthesize_legacy_membership(%{account_id: account_id, id: user_id}, _claims)
       when not is_nil(account_id) do
    case load_real_active_membership(user_id, account_id) do
      %AccountMembership{} = membership ->
        {:ok, membership}

      nil ->
        Logger.warning(
          "legacy access token denied: no active membership found user_id=#{user_id} account_id=#{account_id}"
        )

        {:error, :membership_id_required}
    end
  end

  defp synthesize_legacy_membership(_user, _claims), do: {:error, :membership_id_required}

  defp load_real_active_membership(user_id, account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, account_uuid} ->
        Repo.get_by(AccountMembership,
          user_id: user_id,
          account_id: account_uuid,
          status: :active
        )

      _ ->
        nil
    end
  end
end

defmodule AccountMembershipByIdQuery do
  @moduledoc false
  import Ecto.Query, warn: false

  alias MealPlannerApi.Persistence.Accounts.AccountMembership

  def call(uuid) do
    from(m in AccountMembership, where: m.id == ^uuid)
  end
end
