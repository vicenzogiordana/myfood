defmodule MealPlannerApiWeb.Plugs.LoadCurrentMembershipTest do
  @moduledoc """
  Tests for `MealPlannerApiWeb.Plugs.LoadCurrentMembership` and its
  WebSocket sibling `LoadCurrentMembershipSocket`
  (Phase A — Tenancy Refactor, PR 1 task 1.10).

  Coverage:

    * `access_v2` JWT → `conn.assigns.current_membership` is the
      AccountMembership row identified by `membership_id`
    * `access_v1` (legacy) JWT → `current_membership` is a
      synthesized struct with `__synthesized__: true`, populated from
      `current_user.account_id` + `current_user.role` + `Account.plan`
    * `access_v2` JWT with no `membership_id` claim → halt with
      `401 membership_id_required`
    * `membership_from_socket/1` returns the same shape as the conn
      assign (used by Phoenix Channels)
  """
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembership
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket

  describe "call/2 for HTTP conn" do
    test "access_v2 token populates current_membership from membership_id claim", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "v2@example.com"},
          [
            {%{plan: :family_4, name: "Family V2"}, :owner}
          ]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)
      {:ok, claims} = Guardian.decode_and_verify(token)

      # The plug expects Guardian to have populated conn.assigns[:default]
      # with the user (via Guardian.Plug.LoadResource). In tests we set
      # that key explicitly.
      conn =
        conn
        |> Plug.Conn.put_private(:guardian_default_claims, claims)
        |> Plug.Conn.assign(:default, user)
        |> LoadCurrentMembership.call(%{})

      assert %AccountMembership{id: ms_id, account_id: account_id} = conn.assigns.current_membership
      assert ms_id == membership.id
      assert account_id == membership.account_id
      refute Map.get(conn.assigns.current_membership, :__synthesized__)
    end

    test "access_v1 (legacy) token synthesizes a current_membership from user.account_id", %{conn: conn} do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Synth Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "legacy@example.com",
          name: "Legacy User",
          role: :owner
        })
        |> Repo.insert()

      legacy_claims = %{
        "typ" => "access",
        "account_id" => Ecto.UUID.cast!(account.id),
        "account_type" => "group",
        "email" => user.email,
        "name" => user.name
      }

      conn =
        conn
        |> Plug.Conn.put_private(:guardian_default_claims, legacy_claims)
        |> Plug.Conn.assign(:default, user)
        |> LoadCurrentMembership.call(%{})

      synthesized = conn.assigns.current_membership

      assert Map.get(synthesized, :__synthesized__) == true
      assert synthesized.account_id == account.id
      assert synthesized.role == :owner
      assert synthesized.status == :active
      assert is_nil(synthesized.id)
    end

    test "access_v2 token without membership_id halts with 401 membership_id_required", %{conn: conn} do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Partial V2 Account",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "partial-v2@example.com",
          name: "Partial V2",
          role: :owner
        })
        |> Repo.insert()

      partial_claims = %{
        "typ" => "access_v2",
        "account_id" => Ecto.UUID.cast!(account.id),
        "role" => "owner",
        "plan" => "individual",
        "status" => "active",
        "email" => user.email,
        "name" => user.name
      }

      conn =
        conn
        |> Plug.Conn.put_private(:guardian_default_claims, partial_claims)
        |> Plug.Conn.assign(:default, user)
        |> LoadCurrentMembership.call(%{})

      assert conn.halted
      assert conn.status == 401
      body = json_response(conn, 401)
      assert body["error"] == "membership_id_required"
    end
  end

  describe "membership_from_socket/1" do
    test "returns the conn-equivalent struct for an access_v2 socket" do
      user =
        user_with_memberships(
          %{email: "v2-socket@example.com"},
          [
            {%{plan: :family_4, name: "Family V2 Sock"}, :owner}
          ]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)
      {:ok, claims} = Guardian.decode_and_verify(token)

      socket = %Phoenix.Socket{
        assigns: %{current_user: user, claims: claims}
      }

      loaded = LoadCurrentMembershipSocket.membership_from_socket(socket)

      assert %AccountMembership{id: ms_id} = loaded
      assert Ecto.UUID.cast!(ms_id) == Ecto.UUID.cast!(membership.id)
    end

    test "synthesizes for an access_v1 socket" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Sock Account",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "v1-socket@example.com",
          name: "V1 Socket User",
          role: :member
        })
        |> Repo.insert()

      socket = %Phoenix.Socket{
        assigns: %{
          current_user: user,
          claims: %{"typ" => "access", "account_id" => Ecto.UUID.cast!(account.id)}
        }
      }

      synthesized = LoadCurrentMembershipSocket.membership_from_socket(socket)

      assert Map.get(synthesized, :__synthesized__) == true
      assert synthesized.account_id == account.id
      assert synthesized.role == :member
    end
  end
end
