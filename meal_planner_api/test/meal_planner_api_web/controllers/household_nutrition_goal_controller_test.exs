defmodule MealPlannerApiWeb.HouseholdNutritionGoalControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo

  @valid_goal %{
    "calories" => %{"min" => 1800, "max" => 2200},
    "protein_g" => %{"min" => 90, "max" => 140},
    "carbs_g" => %{"min" => 200, "max" => 300},
    "fat_g" => %{"min" => 50, "max" => 80}
  }

  setup do
    owner =
      user_with_memberships(%{email: "goal_owner@example.test"}, [
        {%{plan: :family_4, name: "Fictitious Household A"}, :owner}
      ])

    [owner_membership] = owner.memberships
    household = owner_membership.account
    {member, member_membership} = add_member(household, "goal_member@example.test")

    outsider =
      user_with_memberships(%{email: "goal_outsider@example.test"}, [
        {%{plan: :family_4, name: "Fictitious Household B"}, :owner}
      ])

    [outsider_membership] = outsider.memberships

    %{
      household: household,
      owner_token: issue_access_v2_token(owner, owner_membership),
      member_token: issue_access_v2_token(member, member_membership),
      outsider_household: outsider_membership.account,
      outsider_token: issue_access_v2_token(outsider, outsider_membership)
    }
  end

  describe "GET /api/accounts/:account_id/settings/nutrition-goal" do
    test "returns null data while the Household has no Nutrition Goal", ctx do
      conn = get(authed(ctx.conn, ctx.member_token), goal_path(ctx.household))

      assert json_response(conn, 200) == %{"data" => nil}
    end

    test "returns the persisted daily ranges per standard portion", ctx do
      put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), @valid_goal)

      conn = get(authed(build_conn(), ctx.member_token), goal_path(ctx.household))
      data = json_response(conn, 200)["data"]

      assert Map.take(data, Map.keys(@valid_goal)) == @valid_goal
      assert data["account_id"] == ctx.household.id
      assert data["per"] == "standard_portion"
      assert data["period"] == "daily"
    end
  end

  describe "PUT /api/accounts/:account_id/settings/nutrition-goal" do
    test "any Member (not only the Owner) can set the Nutrition Goal", ctx do
      conn = put(authed(ctx.conn, ctx.member_token), goal_path(ctx.household), @valid_goal)

      assert Map.take(json_response(conn, 200)["data"], Map.keys(@valid_goal)) == @valid_goal
    end

    test "updating replaces the previous ranges", ctx do
      put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), @valid_goal)

      updated = put_in(@valid_goal, ["calories"], %{"min" => 1500, "max" => 1700})
      conn = put(authed(build_conn(), ctx.member_token), goal_path(ctx.household), updated)
      assert json_response(conn, 200)["data"]["calories"] == %{"min" => 1500, "max" => 1700}

      conn = get(authed(build_conn(), ctx.owner_token), goal_path(ctx.household))
      assert json_response(conn, 200)["data"]["calories"] == %{"min" => 1500, "max" => 1700}
    end

    test "rejects a range whose min is above its max", ctx do
      invalid = put_in(@valid_goal, ["protein_g"], %{"min" => 150, "max" => 100})
      conn = put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), invalid)

      body = json_response(conn, 422)
      assert body["error"] == "invalid_nutrition_goal"
      assert Map.has_key?(body["details"], "protein_g_min")
      assert get_goal(ctx) == nil
    end

    test "rejects negative values", ctx do
      invalid = put_in(@valid_goal, ["fat_g"], %{"min" => -5, "max" => 80})
      conn = put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), invalid)

      body = json_response(conn, 422)
      assert body["error"] == "invalid_nutrition_goal"
      assert Map.has_key?(body["details"], "fat_g_min")
    end

    test "rejects a goal missing a range", ctx do
      invalid = Map.delete(@valid_goal, "carbs_g")
      conn = put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), invalid)

      body = json_response(conn, 422)
      assert body["error"] == "invalid_nutrition_goal"
      assert Map.has_key?(body["details"], "carbs_g_min")
    end

    test "rejects non-numeric bounds", ctx do
      invalid = put_in(@valid_goal, ["calories"], %{"min" => "lots", "max" => 2200})
      conn = put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), invalid)

      assert json_response(conn, 422)["error"] == "invalid_nutrition_goal"
    end

    test "a rejected update keeps the previous goal intact", ctx do
      put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), @valid_goal)

      invalid = put_in(@valid_goal, ["calories"], %{"min" => 3000, "max" => 1000})
      conn = put(authed(build_conn(), ctx.owner_token), goal_path(ctx.household), invalid)
      assert json_response(conn, 422)

      assert get_goal(ctx)["calories"] == @valid_goal["calories"]
    end
  end

  describe "cross-Household isolation" do
    test "another Household cannot read the Nutrition Goal", ctx do
      put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), @valid_goal)

      conn = get(authed(build_conn(), ctx.outsider_token), goal_path(ctx.household))

      assert json_response(conn, 403)["error"] == "account_mismatch"
    end

    test "another Household cannot change the Nutrition Goal", ctx do
      put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), @valid_goal)

      changed = put_in(@valid_goal, ["calories"], %{"min" => 500, "max" => 600})
      conn = put(authed(build_conn(), ctx.outsider_token), goal_path(ctx.household), changed)

      assert json_response(conn, 403)["error"] == "account_mismatch"
      assert get_goal(ctx)["calories"] == @valid_goal["calories"]
    end

    test "each Household only sees its own Nutrition Goal", ctx do
      put(authed(ctx.conn, ctx.owner_token), goal_path(ctx.household), @valid_goal)

      conn = get(authed(build_conn(), ctx.outsider_token), goal_path(ctx.outsider_household))

      assert json_response(conn, 200) == %{"data" => nil}
    end
  end

  test "requires authentication", ctx do
    conn = get(ctx.conn, goal_path(ctx.household))

    assert conn.status == 401
  end

  defp goal_path(household), do: "/api/accounts/#{household.id}/settings/nutrition-goal"

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp get_goal(ctx) do
    build_conn()
    |> authed(ctx.owner_token)
    |> get(goal_path(ctx.household))
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp add_member(household, email) do
    user =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: "Fictitious Member", role: :member})
      |> Repo.insert!()

    membership =
      %AccountMembership{}
      |> AccountMembership.changeset(%{
        account_id: household.id,
        user_id: user.id,
        role: :member,
        status: :active,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert!()
      |> Repo.preload(:account)

    {user, membership}
  end
end
