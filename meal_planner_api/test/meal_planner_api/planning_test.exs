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
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    previous_client = Application.get_env(:meal_planner_api, :planning_optimizer_client)

    on_exit(fn ->
      Application.put_env(:meal_planner_api, :planning_optimizer_client, previous_client)
      Application.delete_env(:meal_planner_api, :planning_optimizer_capture_pid)
    end)
  end

  test "planning days are capped by account subscription plan" do
    %{user: user} = create_identity_with_recipes("u1_plan", "free", "individual")

    assert {:ok, plan} = Planning.weekly_plan_for(user, %{"weekly_budget_cents" => 30_000})

    assert length(plan.days) == 7
    assert plan.max_planning_days == 7
  end

  test "premium tier planning returns 7 days" do
    %{user: user} = create_identity_with_recipes("u2_plan", "premium", "group")

    assert {:ok, plan} = Planning.weekly_plan_for(user, %{"weekly_budget_cents" => 120_000})

    assert length(plan.days) == 7
    assert plan.max_planning_days == 7
  end

  test "weekly_plan_for returns exceeds_max_planning_days when requested days exceed account plan" do
    %{user: user} = create_identity_with_recipes("u_days_limit", "free", "individual")

    assert {:error, :exceeds_max_planning_days} =
             Planning.weekly_plan_for(user, %{"days" => 8})
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

    assert {:ok, _plan} =
             Planning.weekly_plan_for(user, %{
               "kcal_target" => 2000,
               "weekly_budget_cents" => 40_000
             })

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

  test "confirm_plan persists scheduled meals" do
    %{user: user, recipes: recipes, account: account} =
      create_identity_with_recipes("u_confirm_ctx", "premium", "group")

    today = Date.utc_today()
    tomorrow = Date.add(today, 1)

    payload = %{
      "meals" => [
        %{
          "date" => Date.to_iso8601(today),
          "slot" => "breakfast",
          "recipe_id" => recipes.breakfast.id
        },
        %{"date" => Date.to_iso8601(tomorrow), "slot" => "lunch", "recipe_id" => recipes.lunch.id}
      ]
    }

    assert {:ok, result} = Planning.confirm_plan(user, payload)
    assert result.scheduled_meals_count == 2

    persisted =
      MealPlannerApi.Persistence.Planning.list_scheduled_meals(account.id, today, tomorrow)

    assert length(persisted) == 2
    assert Enum.any?(persisted, &(&1.recipe_id == recipes.breakfast.id and &1.slot == :breakfast))
    assert Enum.any?(persisted, &(&1.recipe_id == recipes.lunch.id and &1.slot == :lunch))
  end

  test "confirm_plan returns error for unknown recipe" do
    %{user: user} = create_identity_with_recipes("u_confirm_invalid", "free", "individual")

    payload = %{
      "meals" => [
        %{
          "date" => Date.to_iso8601(Date.utc_today()),
          "slot" => "dinner",
          "recipe_id" => Ecto.UUID.generate()
        }
      ]
    }

    assert {:error, :recipe_not_found} = Planning.confirm_plan(user, payload)
  end

  defp create_identity_with_recipes(user_id, subscription_tier, account_type) do
    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => user_id,
        "account_id" => "acct_#{user_id}",
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
      account: account,
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
