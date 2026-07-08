defmodule MealPlannerApiWeb.AccountLifecycleControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  describe "POST /api/auth/switch-account (task 3.5)" do
    test "a multi-familia User can switch to a second :active Account", %{conn: conn} do
      user =
        user_with_memberships(%{email: "switcher_a@example.com"}, [
          {%{plan: :family_4, name: "Family Switch A1"}, :owner},
          {%{plan: :individual, name: "Family Switch A2"}, :owner}
        ])

      [membership_1, membership_2] = user.memberships
      token = issue_access_v2_token(user, membership_1)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/auth/switch-account", %{"membership_id" => membership_2.id})

      body = json_response(conn, 200)

      assert is_binary(body["access_token"])
      assert body["membership"]["account_id"] == membership_2.account_id
      assert body["account"]["id"] == membership_2.account_id
    end

    test "switching to another User's membership returns 403 not_your_membership", %{
      conn: conn
    } do
      user =
        user_with_memberships(%{email: "switcher_b@example.com"}, [
          {%{plan: :family_4, name: "Family Switch B"}, :owner}
        ])

      [membership_b] = user.memberships
      token = issue_access_v2_token(user, membership_b)

      other_user =
        user_with_memberships(%{email: "switcher_other@example.com"}, [
          {%{plan: :individual, name: "Other's Account"}, :owner}
        ])

      [other_membership] = other_user.memberships

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/auth/switch-account", %{"membership_id" => other_membership.id})

      assert json_response(conn, 403)["error"] == "not_your_membership"
    end

    test "switching to a :suspended membership returns 409 membership_not_active", %{
      conn: conn
    } do
      user =
        user_with_memberships(%{email: "switcher_c@example.com"}, [
          {%{plan: :family_4, name: "Family Switch C1"}, :owner}
        ])

      [membership_c1] = user.memberships
      token = issue_access_v2_token(user, membership_c1)

      other_owner =
        user_with_memberships(%{email: "switcher_c_other_owner@example.com"}, [
          {%{plan: :individual, name: "Family Switch C2"}, :owner}
        ])

      [other_owner_membership] = other_owner.memberships

      suspended_membership =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: other_owner_membership.account_id,
          user_id: user.id,
          role: :member,
          status: :suspended,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/auth/switch-account", %{"membership_id" => suspended_membership.id})

      assert json_response(conn, 409)["error"] == "membership_not_active"
    end
  end
end
