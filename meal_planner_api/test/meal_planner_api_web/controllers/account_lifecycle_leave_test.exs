defmodule MealPlannerApiWeb.AccountLifecycleLeaveTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

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
