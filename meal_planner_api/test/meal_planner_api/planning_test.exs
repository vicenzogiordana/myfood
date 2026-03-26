defmodule MealPlannerApi.PlanningTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Shopping
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Planning

  setup do
    :ok = Sandbox.checkout(Repo)

    previous_client = Application.get_env(:meal_planner_api, :planning_optimizer_client)

    on_exit(fn ->
      Application.put_env(:meal_planner_api, :planning_optimizer_client, previous_client)
      Application.delete_env(:meal_planner_api, :planning_optimizer_capture_pid)
    end)
  end

  test "free tier planning is capped to 3 days" do
    %{user: user} = create_identity_with_recipes("u1_plan", "free", "individual")

    plan = Planning.weekly_plan_for(user, %{"weekly_budget_cents" => 30_000})

    assert length(plan.days) == 3
    assert plan.max_planning_days == 3
  end

  test "premium tier planning returns 7 days" do
    %{user: user} = create_identity_with_recipes("u2_plan", "premium", "group")

    plan = Planning.weekly_plan_for(user, %{"weekly_budget_cents" => 120_000})

    assert length(plan.days) == 7
    assert plan.max_planning_days == 7
  end

  test "optimizer payload includes macro bounds and uses latest historical recipe cost" do
    Application.put_env(
      :meal_planner_api,
      :planning_optimizer_client,
      MealPlannerApi.PlanningCaptureOptimizerClient
    )

    Application.put_env(:meal_planner_api, :planning_optimizer_capture_pid, self())

    %{user: user, recipes: recipes} =
      create_identity_with_recipes("u_payload", "free", "individual")

    {:ok, supermarket} =
      Shopping.upsert_supermarket_by_name(%{
        name: "Super payload planning",
        chain: "Payload Chain",
        pricing_scrape_enabled: true
      })

    yesterday = Date.add(Date.utc_today(), -1)
    three_days_ago = Date.add(Date.utc_today(), -3)

    {:ok, _older_cost} =
      Catalog.upsert_recipe_daily_cost(%{
        recipe_id: recipes.breakfast.id,
        supermarket_id: supermarket.id,
        total_cents_ars: 4400,
        date: three_days_ago
      })

    {:ok, _latest_historical_cost} =
      Catalog.upsert_recipe_daily_cost(%{
        recipe_id: recipes.breakfast.id,
        supermarket_id: supermarket.id,
        total_cents_ars: 3200,
        date: yesterday
      })

    _plan =
      Planning.weekly_plan_for(user, %{"kcal_target" => 2000, "weekly_budget_cents" => 40_000})

    assert_receive {:optimizer_payload, payload}

    macro_bounds = payload["constraints"]["macro_bounds"]
    assert macro_bounds["protein_g"] == %{"min" => 100.0, "max" => 150.0}
    assert macro_bounds["carbs_g"] == %{"min" => 225.0, "max" => 325.0}
    assert macro_bounds["fat_g"] == %{"min" => 44.44, "max" => 77.78}

    breakfast_candidates = payload["candidates_by_slot"]["breakfast"]

    breakfast_candidate =
      Enum.find(breakfast_candidates, fn candidate ->
        candidate["recipe_id"] == recipes.breakfast.id
      end)

    assert breakfast_candidate["estimated_cost_cents"] == 3200
  end

  defp create_identity_with_recipes(user_id, subscription_tier, account_type) do
    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => user_id,
        "subscription_tier" => subscription_tier,
        "account_type" => account_type
      })

    {:ok, _breakfast} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Avena #{user_id}",
        source: :user_created,
        servings: 1,
        calories_per_serving: 450,
        suitable_for_slots: [:breakfast]
      })

    {:ok, _lunch} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Pollo #{user_id}",
        source: :user_created,
        servings: 1,
        calories_per_serving: 700,
        suitable_for_slots: [:lunch]
      })

    {:ok, _dinner} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Tortilla #{user_id}",
        source: :user_created,
        servings: 1,
        calories_per_serving: 650,
        suitable_for_slots: [:dinner]
      })

    user =
      user
      |> Map.put(:account_type, if(account_type == "group", do: :group, else: :individual))
      |> Map.put(
        :subscription_tier,
        if(subscription_tier == "premium", do: :premium, else: :free)
      )

    %{
      user: user,
      recipes: %{
        breakfast:
          Repo.get_by!(MealPlannerApi.Persistence.Catalog.Recipe, name: "Avena #{user_id}"),
        lunch: Repo.get_by!(MealPlannerApi.Persistence.Catalog.Recipe, name: "Pollo #{user_id}"),
        dinner:
          Repo.get_by!(MealPlannerApi.Persistence.Catalog.Recipe, name: "Tortilla #{user_id}")
      }
    }
  end
end
