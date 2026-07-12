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
      (post-PR-3b review BLOCKER fix — see `synthesize_legacy_membership/1`
      below; this module no longer fabricates an in-memory struct).

  Channels that need the membership call
  `LoadCurrentMembershipSocket.membership_from_socket(socket)` and read
  `socket.assigns.current_membership` (Q8 — design §7).
  """

  require Logger

  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  @spec membership_from_socket(Phoenix.Socket.t()) ::
          AccountMembership.t() | nil
  def membership_from_socket(%Phoenix.Socket{} = socket) do
    current_user = socket.assigns[:current_user]
    claims = socket.assigns[:claims] || %{}
    typ = Map.get(claims, "typ", "access")

    case typ do
      "access_v2" -> load_access_v2_membership(claims)
      "access" -> synthesize_legacy_membership(current_user)
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
      "access" -> synthesize_legacy_membership(current_user)
      _ -> nil
    end
  end

  defp load_access_v2_membership(claims) do
    case Map.get(claims, "membership_id") do
      nil -> nil
      "" -> nil
      membership_id -> load_membership_by_id(membership_id)
    end
  end

  defp load_membership_by_id(membership_id) do
    case Ecto.UUID.cast(membership_id) do
      {:ok, uuid} ->
        import Ecto.Query, warn: false
        alias MealPlannerApi.Persistence.Accounts.AccountMembership

        from(m in AccountMembership, where: m.id == ^uuid)
        |> Repo.one()
        |> Repo.preload(:account)

      _ ->
        nil
    end
  end

  # Post-PR-3b review — BLOCKER fix (legacy membership synthesis). See
  # `MealPlannerApiWeb.Plugs.LoadCurrentMembership.synthesize_legacy_membership/2`
  # for the full rationale — the short version: fabricating an
  # `:active` membership from `user.account_id` alone let a removed
  # member's stale legacy token keep working for up to Guardian's
  # 4-week token TTL, since `remove_member/3`/`leave/2` hard-delete the
  # real row without clearing `user.account_id`. We now require a real,
  # `:active` row.
  defp synthesize_legacy_membership(%{account_id: account_id, id: user_id})
       when not is_nil(account_id) do
    case load_real_active_membership(user_id, account_id) do
      nil ->
        Logger.warning(
          "legacy access token denied: no active membership found user_id=#{user_id} account_id=#{account_id}"
        )

        nil

      %AccountMembership{} = membership ->
        membership
    end
  end

  defp synthesize_legacy_membership(_), do: nil

  defp load_real_active_membership(user_id, account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, account_uuid} ->
        AccountMembership
        |> Repo.get_by(user_id: user_id, account_id: account_uuid, status: :active)
        |> maybe_preload_account()

      _ ->
        nil
    end
  end

  defp maybe_preload_account(nil), do: nil

  defp maybe_preload_account(%AccountMembership{} = membership),
    do: Repo.preload(membership, :account)
end
