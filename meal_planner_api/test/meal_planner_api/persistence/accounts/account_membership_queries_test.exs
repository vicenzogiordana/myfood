defmodule MealPlannerApi.Persistence.Accounts.AccountMembershipQueriesTest do
  @moduledoc """
  Tests for the `access_v2` membership-status enforcement gap (tenancy
  debt cleanup item 2).

  ## Investigation summary

  `AccountMembershipQueries.load_membership_by_id/2` (the `access_v2`
  token path) does a bare by-id lookup with NO `status` filter — unlike
  `load_active_membership/3` (the legacy path), which already requires
  `status: :active`. The initial hypothesis was that this was a
  blanket oversight affecting all 3 call sites
  (`LoadCurrentMembership`, `LoadCurrentMembershipSocket`,
  `AccountsMembership.current_membership/2`).

  That hypothesis was WRONG for the socket/channel path: adding
  `status: :active` to the shared query broke 4 existing tests
  (`ai_channel_test.exs`, `calendar_channel_test.exs`,
  `cooking_channel_test.exs`, `planning_channel_test.exs` — all named
  "... (non-active) membership join is rejected"). Those tests
  establish a deliberate, already-shipped design (Q8 — design §7):
  `UserSocket.connect/3` must succeed even for a non-`:active` (e.g.
  `:invited`) membership, and each Channel's `join/3` re-fetches the
  membership itself and checks `status != :active` to return a
  specific `{:error, %{reason: "forbidden"}}` at JOIN time rather than
  a generic CONNECT failure.

  So the real, live gap is narrower: the HTTP plug
  (`LoadCurrentMembership.load_access_v2_membership/1`) and the
  application-layer resolver
  (`AccountsMembership.load_v2_membership/1`) have NO status-aware
  caller downstream (no HTTP equivalent of the channel's own
  `status != :active` check exists — `EnforceAccountScope` only checks
  `account_id`, not `status`). Those two are the ones fixed here. The
  shared query and the socket plug are intentionally left
  status-agnostic; see their moduledocs for the full rationale.
  """
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.AccountMembershipQueries
  alias MealPlannerApi.Repo
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembership
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket

  describe "AccountMembershipQueries.load_membership_by_id/2 (raw, status-agnostic)" do
    test "returns the membership when status is :active" do
      user =
        user_with_memberships(
          %{email: "queries-active@example.com"},
          [{%{plan: :individual, name: "Queries Active"}, :owner}]
        )

      [membership] = user.memberships

      assert %AccountMembership{id: id} =
               AccountMembershipQueries.load_membership_by_id(membership.id)

      assert id == membership.id
    end

    test "regression guard: still returns a :suspended membership (callers must check status themselves)" do
      user =
        user_with_memberships(
          %{email: "queries-suspended@example.com"},
          [{%{plan: :individual, name: "Queries Suspended"}, :owner}]
        )

      [membership] = user.memberships

      {:ok, suspended} =
        membership
        |> AccountMembership.changeset(%{status: :suspended})
        |> Repo.update()

      assert %AccountMembership{status: :suspended} =
               AccountMembershipQueries.load_membership_by_id(suspended.id)
    end

    test "returns nil for a non-UUID membership_id" do
      assert AccountMembershipQueries.load_membership_by_id("not-a-uuid") == nil
    end
  end

  describe "LoadCurrentMembership plug (HTTP, access_v2) requires status: :active" do
    test "an :active membership is accepted", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "http-active@example.com"},
          [{%{plan: :family_4, name: "HTTP Active Family"}, :owner}]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)
      {:ok, claims} = Guardian.decode_and_verify(token)

      conn =
        conn
        |> Plug.Conn.put_private(:guardian_default_claims, claims)
        |> Plug.Conn.assign(:default, user)
        |> LoadCurrentMembership.call(%{})

      refute conn.halted
      assert conn.assigns.current_membership.id == membership.id
    end

    test "a :suspended membership is rejected (was previously accepted — the bug)", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "http-suspended@example.com"},
          [{%{plan: :family_4, name: "HTTP Suspended Family"}, :owner}]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)
      {:ok, claims} = Guardian.decode_and_verify(token)

      {:ok, _suspended} =
        membership
        |> AccountMembership.changeset(%{status: :suspended})
        |> Repo.update()

      conn =
        conn
        |> Plug.Conn.put_private(:guardian_default_claims, claims)
        |> Plug.Conn.assign(:default, user)
        |> LoadCurrentMembership.call(%{})

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "membership_id_required"
    end
  end

  describe "AccountsMembership.current_membership/2 (app layer, access_v2) requires status: :active" do
    test "an :active membership is accepted" do
      user =
        user_with_memberships(
          %{email: "app-active@example.com"},
          [{%{plan: :family_4, name: "App Active Family"}, :owner}]
        )

      [membership] = user.memberships
      claims = %{"typ" => "access_v2", "membership_id" => to_string(membership.id)}

      assert %AccountMembership{id: id} = AccountsMembership.current_membership(user, claims)
      assert id == membership.id
    end

    test "a :suspended membership is rejected (was previously accepted — the bug)" do
      user =
        user_with_memberships(
          %{email: "app-suspended@example.com"},
          [{%{plan: :family_4, name: "App Suspended Family"}, :owner}]
        )

      [membership] = user.memberships

      {:ok, suspended} =
        membership
        |> AccountMembership.changeset(%{status: :suspended})
        |> Repo.update()

      claims = %{"typ" => "access_v2", "membership_id" => to_string(suspended.id)}

      assert AccountsMembership.current_membership(user, claims) == nil
    end
  end

  describe "LoadCurrentMembershipSocket regression guard: socket/channel path stays status-agnostic" do
    test "membership_from_socket/1 still returns a :suspended membership (channels enforce status themselves)" do
      user =
        user_with_memberships(
          %{email: "socket-suspended@example.com"},
          [{%{plan: :family_4, name: "Socket Suspended Family"}, :owner}]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)
      {:ok, claims} = Guardian.decode_and_verify(token)

      {:ok, _suspended} =
        membership
        |> AccountMembership.changeset(%{status: :suspended})
        |> Repo.update()

      socket = %Phoenix.Socket{assigns: %{current_user: user, claims: claims}}

      assert %AccountMembership{status: :suspended} =
               LoadCurrentMembershipSocket.membership_from_socket(socket)
    end
  end
end
