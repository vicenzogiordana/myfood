defmodule MealPlannerApi.PlanningTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Accounts.User
  alias MealPlannerApi.Planning

  test "free tier planning is capped to 3 days" do
    user = %User{
      id: "u1",
      account_id: "acct_u1",
      account_type: :individual,
      subscription_tier: :free
    }

    plan = Planning.weekly_plan_for(user, %{"weekly_budget_cents" => 30_000})

    assert length(plan.days) == 3
    assert plan.max_planning_days == 3
  end

  test "premium tier planning returns 7 days" do
    user = %User{
      id: "u2",
      account_id: "acct_u2",
      account_type: :group,
      subscription_tier: :premium
    }

    plan = Planning.weekly_plan_for(user, %{"weekly_budget_cents" => 120_000})

    assert length(plan.days) == 7
    assert plan.max_planning_days == 7
  end
end
