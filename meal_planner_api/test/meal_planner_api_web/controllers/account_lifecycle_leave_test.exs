defmodule MealPlannerApiWeb.AccountLifecycleLeaveTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo

  describe "POST /api/accounts/:account_id/leave (task 3.6)" do
    test "a :member leaving returns 204 and the row is gone", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_leave_a@example.com"}, [
          {%{plan: :family_4, name: "Family Leave A"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      member_user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "member_leave_a@example.com",
          name: "Member Leave A",
          role: :member
        })
        |> Repo.insert!()

      member_membership =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: member_user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      token = issue_access_v2_token(member_user, member_membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/accounts/#{account.id}/leave", %{})

      assert response(conn, 204)
      refute Repo.get(AccountMembership, member_membership.id)
    end

    test "a :member with only a legacy access_v1 token (synthesized membership) can still leave",
         %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_leave_legacy@example.com"}, [
          {%{plan: :family_4, name: "Family Leave Legacy"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      member_user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "member_leave_legacy@example.com",
          name: "Member Leave Legacy",
          role: :member
        })
        |> Repo.insert!()

      member_membership =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: member_user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      # Legacy access_v1 claim shape (design §3.1) minted manually — same
      # pattern as membership_controller_test.exs's "dangling account"
      # test. `LoadCurrentMembership` synthesizes a virtual membership
      # (`id: nil`) from `current_user.account_id` (set from the CLAIM by
      # `Guardian.resource_from_claims/1`, not the DB row) + `user.role`.
      # This proves `AccountsMembership.leave/2` works for a real
      # `:member` row even when the actor struct it receives has no real
      # `id` (bug: `leave/2` used to look up by `id: actor.id`, which is
      # always `nil` for synthesized memberships).
      claims = %{
        "account_id" => account.id,
        "account_type" => "individual",
        "subscription_tier" => "free",
        "email" => member_user.email,
        "name" => member_user.name
      }

      {:ok, token, _claims} = Guardian.encode_and_sign(member_user, claims, token_type: "access")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/accounts/#{account.id}/leave", %{})

      assert response(conn, 204)
      refute Repo.get(AccountMembership, member_membership.id)
    end

    test "the :owner leaving returns 403 cannot_leave_owned_account", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_leave_b@example.com"}, [
          {%{plan: :family_4, name: "Family Leave B"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account
      token = issue_access_v2_token(owner, owner_membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/accounts/#{account.id}/leave", %{})

      assert json_response(conn, 403)["error"] == "cannot_leave_owned_account"
      assert Repo.get(AccountMembership, owner_membership.id)
    end
  end
end
