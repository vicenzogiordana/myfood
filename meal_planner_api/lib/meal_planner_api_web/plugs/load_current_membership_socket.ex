defmodule MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket do
  @moduledoc """
  Sibling of `MealPlannerApiWeb.Plugs.LoadCurrentMembership` for
  Phoenix Channels (PR 1 task 1.10).

  Reads `socket.assigns.current_user` and `socket.assigns.claims` (both
  populated by `UserSocket.connect/3` after Guardian verifies the JWT)
  and resolves the active membership the same way the HTTP plug does:

    * `typ: "access_v2"` → load the `AccountMembership` row by
      `claims["membership_id"]`
    * `typ: "access"` (legacy fallback) → loads the real, `:active`
      `AccountMembership` row for `(current_user.id,
      current_user.account_id)`. Returns `nil` if no such row exists
      (post-PR-3b review BLOCKER fix — see `load_real_legacy_membership/1`
      below; this module no longer fabricates an in-memory struct).

  Both lookups delegate to
  `MealPlannerApi.Persistence.Accounts.AccountMembershipQueries`, the
  single shared query module for all "load the real membership" call
  sites (this module, `LoadCurrentMembership`, and
  `AccountsMembership.current_membership/2`).

  Channels that need the membership call
  `LoadCurrentMembershipSocket.membership_from_socket(socket)` and read
  `socket.assigns.current_membership` (Q8 — design §7).
  """

  require Logger

  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.AccountMembershipQueries

  @spec membership_from_socket(Phoenix.Socket.t()) ::
          AccountMembership.t() | nil
  def membership_from_socket(%Phoenix.Socket{} = socket) do
    current_user = socket.assigns[:current_user]
    claims = socket.assigns[:claims] || %{}
    typ = Map.get(claims, "typ", "access")

    case typ do
      "access_v2" -> load_access_v2_membership(claims)
      "access" -> load_real_legacy_membership(current_user)
      _ -> nil
    end
  end

  @doc """
  Convenience that reads the membership from a Conn (HTTP) the same way
  the HTTP plug does. Provided so channel tests that have a conn shape
  can exercise the membership loading logic without instantiating a
  full Phoenix.Socket struct.
  """
  @spec membership_from_conn(Plug.Conn.t()) :: AccountMembership.t() | nil
  def membership_from_conn(%Plug.Conn{} = conn) do
    claims =
      conn.private[:guardian_default_claims] ||
        conn.assigns[:guardian_default_claims] || %{}

    current_user =
      try do
        MealPlannerApi.Auth.Guardian.Plug.current_resource(conn)
      rescue
        _ -> nil
      end

    typ = Map.get(claims, "typ", "access")

    case typ do
      "access_v2" -> load_access_v2_membership(claims)
      "access" -> load_real_legacy_membership(current_user)
      _ -> nil
    end
  end

  # Deliberately does NOT check `status: :active` here (tenancy debt
  # cleanup item 2 investigated adding it and reverted — it broke
  # channel joins). `UserSocket.connect/3` must succeed even for a
  # non-`:active` (e.g. `:invited`) membership; each channel's
  # `join/3` re-fetches the membership via `membership_from_socket/1`
  # and checks `status != :active` itself so it can return a specific
  # `{:error, %{reason: "forbidden"}}` — see e.g.
  # `MealPlannerApiWeb.CalendarChannel.join/3`. If you need active-only
  # semantics with NO status-aware caller downstream, that's the HTTP
  # plug's job (`LoadCurrentMembership.load_access_v2_membership/1`) or
  # `AccountsMembership.load_v2_membership/1`, not this module.
  defp load_access_v2_membership(claims) do
    case Map.get(claims, "membership_id") do
      nil ->
        nil

      "" ->
        nil

      membership_id ->
        AccountMembershipQueries.load_membership_by_id(membership_id, preload: [:account])
    end
  end

  # Post-PR-3b review — BLOCKER fix (legacy membership synthesis). See
  # `MealPlannerApiWeb.Plugs.LoadCurrentMembership.load_real_legacy_membership/2`
  # for the full rationale — the short version: fabricating an
  # `:active` membership from `user.account_id` alone let a removed
  # member's stale legacy token keep working for up to Guardian's
  # 4-week token TTL, since `remove_member/3`/`leave/2` hard-delete the
  # real row without clearing `user.account_id`. We now require a real,
  # `:active` row. (Renamed from `synthesize_legacy_membership/1` — it
  # hasn't synthesized anything since this fix.)
  defp load_real_legacy_membership(%{account_id: account_id, id: user_id})
       when not is_nil(account_id) do
    case AccountMembershipQueries.load_active_membership(user_id, account_id, preload: [:account]) do
      nil ->
        Logger.warning(
          "legacy access token denied: no active membership found user_id=#{user_id} account_id=#{account_id}"
        )

        nil

      %AccountMembership{} = membership ->
        membership
    end
  end

  defp load_real_legacy_membership(_), do: nil
end
