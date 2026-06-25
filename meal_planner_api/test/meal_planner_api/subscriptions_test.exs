defmodule MealPlannerApi.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  test "get_plan_by_name fetches seeded plan from database" do
    assert {:ok, plan} = Subscriptions.get_plan_by_name("family_4")
    assert plan.name == "family_4"
    assert plan.max_users == 4
    assert plan.max_planning_days == 7
  end

  test "max_planning_days resolves from account plan" do
    {:ok, account} =
      MealPlannerApi.Persistence.Accounts.create_account(%{
        name: "Subscription test account",
        plan: :family_4,
        default_budget_cents: 50_000
      })

    assert {:ok, 7} = Subscriptions.max_planning_days(account.id)
  end
end
