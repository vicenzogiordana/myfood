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

  import ExUnit.CaptureLog
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

      assert %AccountMembership{id: ms_id, account_id: account_id} =
               conn.assigns.current_membership

      assert ms_id == membership.id
      assert account_id == membership.account_id
      refute Map.get(conn.assigns.current_membership, :__synthesized__)
    end

    # ------------------------------------------------------------------
    # Post-PR-3b review — BLOCKER fix (legacy membership synthesis).
    #
    # Legacy `typ: "access"` (access_v1) JWTs used to be trusted blindly:
    # the plug synthesized an in-memory `%AccountMembership{status:
    # :active}` straight from `user.account_id`, with NO database lookup
    # at all. Since `remove_member/3` / `leave/2` hard-delete the
    # `AccountMembership` row without ever clearing `user.account_id`,
    # and Guardian's `access` tokens carry a 4-week TTL with no
    # server-side revocation, a removed member's stale token retained
    # full access for up to 4 weeks. The plug now REQUIRES a real,
    # `:active` `AccountMembership` row before granting access — it no
    # longer fabricates one. PR 1's backfill migration (task 1.4) plus
    # PR 2b's atomic `register_with_password/1` (and this fix's own
    # `Accounts.find_or_create_identity/1` upsert) guarantee every
    # currently-valid legacy member has such a row.
    # ------------------------------------------------------------------
    test "access_v1 (legacy) token with no real membership row is rejected (fail-closed)", %{
      conn: conn
    } do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy No-Row Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "legacy-no-row@example.com",
          name: "Legacy No Row User",
          role: :owner
        })
        |> Repo.insert()

      # No AccountMembership row is ever created for this user/account —
      # this models both a "never actually a member" scenario and (via
      # the next test) the post-removal state.
      legacy_claims = %{
        "typ" => "access",
        "account_id" => Ecto.UUID.cast!(account.id),
        "account_type" => "group",
        "email" => user.email,
        "name" => user.name
      }

      log =
        capture_log(fn ->
          conn =
            conn
            |> Plug.Conn.put_private(:guardian_default_claims, legacy_claims)
            |> Plug.Conn.assign(:default, user)
            |> LoadCurrentMembership.call(%{})

          assert conn.halted
          assert conn.status == 401
          assert json_response(conn, 401)["error"] == "membership_id_required"
        end)

      # Post-review fix (BLOCKER item 1): this fail-closed denial MUST be
      # observable — without it, a mass lockout after a future regression
      # would be undetectable until users complain. Asserts user_id +
      # account_id are logged for correlation, NOT the raw token/claims.
      assert log =~ "legacy access token denied"
      assert log =~ "user_id=#{user.id}"
      assert log =~ "account_id=#{account.id}"
    end

    test "access_v1 (legacy) token with a real active membership row returns the real row (no synthesis)",
         %{conn: conn} do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Real Row Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "legacy-real-row@example.com",
          name: "Legacy Real Row User",
          role: :member
        })
        |> Repo.insert()

      {:ok, membership} =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
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

      loaded = conn.assigns.current_membership

      refute Map.get(loaded, :__synthesized__)
      assert loaded.id == membership.id
      assert loaded.account_id == account.id
      assert loaded.role == :member
      assert loaded.status == :active
    end

    test "a removed member's stale legacy token is rejected (membership row hard-deleted)", %{
      conn: conn
    } do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Removed Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "legacy-removed@example.com",
          name: "Legacy Removed User",
          role: :member
        })
        |> Repo.insert()

      {:ok, membership} =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert()

      legacy_claims = %{
        "typ" => "access",
        "account_id" => Ecto.UUID.cast!(account.id),
        "account_type" => "group",
        "email" => user.email,
        "name" => user.name
      }

      # Simulate `AccountsMembership.remove_member/3`'s effect: hard-delete
      # the membership row. `user.account_id` (and the stale JWT claim
      # minted before removal) still point at the account — the request
      # below must now be denied.
      Repo.delete!(membership)

      conn =
        conn
        |> Plug.Conn.put_private(:guardian_default_claims, legacy_claims)
        |> Plug.Conn.assign(:default, user)
        |> LoadCurrentMembership.call(%{})

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "membership_id_required"
    end

    test "access_v2 token without membership_id halts with 401 membership_id_required", %{
      conn: conn
    } do
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

    test "returns nil for an access_v1 socket with no real membership row (fail-closed)" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Sock No-Row Account",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "v1-socket-no-row@example.com",
          name: "V1 Socket No Row User",
          role: :member
        })
        |> Repo.insert()

      socket = %Phoenix.Socket{
        assigns: %{
          current_user: user,
          claims: %{"typ" => "access", "account_id" => Ecto.UUID.cast!(account.id)}
        }
      }

      log =
        capture_log(fn ->
          assert LoadCurrentMembershipSocket.membership_from_socket(socket) == nil
        end)

      assert log =~ "legacy access token denied"
      assert log =~ "user_id=#{user.id}"
      assert log =~ "account_id=#{account.id}"
    end

    test "returns the real active membership row for an access_v1 socket (no synthesis)" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Sock Real Row Account",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "v1-socket-real-row@example.com",
          name: "V1 Socket Real Row User",
          role: :member
        })
        |> Repo.insert()

      {:ok, membership} =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert()

      socket = %Phoenix.Socket{
        assigns: %{
          current_user: user,
          claims: %{"typ" => "access", "account_id" => Ecto.UUID.cast!(account.id)}
        }
      }

      loaded = LoadCurrentMembershipSocket.membership_from_socket(socket)

      refute Map.get(loaded, :__synthesized__)
      assert loaded.id == membership.id
      assert loaded.account_id == account.id
      assert loaded.role == :member
    end

    test "rejects a removed member's stale access_v1 socket (membership row hard-deleted)" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Sock Removed Account",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "v1-socket-removed@example.com",
          name: "V1 Socket Removed User",
          role: :member
        })
        |> Repo.insert()

      {:ok, membership} =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert()

      # Simulate remove_member/3's effect.
      Repo.delete!(membership)

      socket = %Phoenix.Socket{
        assigns: %{
          current_user: user,
          claims: %{"typ" => "access", "account_id" => Ecto.UUID.cast!(account.id)}
        }
      }

      assert LoadCurrentMembershipSocket.membership_from_socket(socket) == nil
    end
  end
end
