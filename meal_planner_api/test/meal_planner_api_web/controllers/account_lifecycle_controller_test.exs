defmodule MealPlannerApiWeb.AccountLifecycleControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
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

  # Post-review fix pass, item 2: `switch_account/2` must consult the
  # same `MEAL_PLANNER_TENANCY_V2` flag `auth_controller.ex` uses, instead
  # of unconditionally minting `access_v2` regardless of the flag.
  describe "tenancy_v2_only flag (post-review fix)" do
    setup do
      previous = Application.get_env(:meal_planner_api, :tenancy_v2_only)

      on_exit(fn ->
        Application.put_env(:meal_planner_api, :tenancy_v2_only, previous)
      end)

      :ok
    end

    test "switch_account mints access (not access_v2) when the flag is off", %{conn: conn} do
      user =
        user_with_memberships(%{email: "switcher_flagoff@example.com"}, [
          {%{plan: :family_4, name: "Family Switch FlagOff 1"}, :owner},
          {%{plan: :individual, name: "Family Switch FlagOff 2"}, :owner}
        ])

      [membership_1, membership_2] = user.memberships
      token = issue_access_v2_token(user, membership_1)

      Application.put_env(:meal_planner_api, :tenancy_v2_only, false)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/auth/switch-account", %{"membership_id" => membership_2.id})

      body = json_response(conn, 200)
      {:ok, claims} = Guardian.decode_and_verify(body["access_token"])

      assert claims["typ"] == "access"
      refute Map.has_key?(claims, "membership_id")
    end
  end
end
