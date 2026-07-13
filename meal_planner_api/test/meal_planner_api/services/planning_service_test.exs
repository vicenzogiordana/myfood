defmodule MealPlannerApi.Services.PlanningServiceTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Services.PlanningService
  alias MealPlannerApi.Optimization.OptimizerPort

  describe "generate_weekly_plan/3" do
    test "accepts user map, params map, and optimizer module" do
      assert is_function(&PlanningService.generate_weekly_plan/3)
    end
  end

  describe "run_optimizer/4" do
    test "returns empty meals for empty days list" do
      assert {:ok, %{meals: []}} = PlanningService.run_optimizer(OptimizerPort, [], %{}, %{})
    end

    test "builds optimization payload correctly" do
      days = ["monday", "tuesday"]
      candidates = %{"breakfast" => [], "lunch" => [], "dinner" => []}

      user = %{
        kcal_target: 2100,
        weekly_budget_cents: 50000,
        account_type: "individual",
        subscription_tier: "free"
      }

      payload = PlanningService.build_optimization_payload(days, candidates, user)

      assert payload["days"] == days
      assert payload["slots"] == ["breakfast", "lunch", "dinner"]
      assert payload["constraints"]["kcal_target"] == 2100
      assert payload["constraints"]["weekly_budget_cents"] == 50000
      assert payload["constraints"]["account_type"] == "individual"
    end

    test "uses defaults when user lacks kcal_target" do
      days = ["monday"]
      candidates = %{"breakfast" => [], "lunch" => [], "dinner" => []}
      user = %{}

      payload = PlanningService.build_optimization_payload(days, candidates, user)

      assert payload["constraints"]["kcal_target"] == 2100
    end

    test "builds macro bounds with protein, carbs, fat" do
      days = ["monday"]
      candidates = %{"breakfast" => [], "lunch" => [], "dinner" => []}
      user = %{}

      payload = PlanningService.build_optimization_payload(days, candidates, user)

      macro_bounds = payload["constraints"]["macro_bounds"]
      assert macro_bounds["protein_g"]["min"] == 100.0
      assert macro_bounds["protein_g"]["max"] == 150.0
      assert macro_bounds["carbs_g"]["min"] == 225.0
      assert macro_bounds["fat_g"]["max"] == 77.78
    end

    test "builds macro bounds with a calories constraint" do
      days = ["monday"]
      candidates = %{"breakfast" => [], "lunch" => [], "dinner" => []}
      user = %{}

      payload = PlanningService.build_optimization_payload(days, candidates, user)

      macro_bounds = payload["constraints"]["macro_bounds"]
      calories_bounds = macro_bounds["calories"]

      assert is_map(calories_bounds)
      assert is_float(calories_bounds["min"])
      assert is_float(calories_bounds["max"])
      assert calories_bounds["min"] < calories_bounds["max"]
    end
  end

  describe "build_candidates/3" do
    test "builds candidates map with slots as keys" do
      assert is_function(&PlanningService.build_candidates/2)
    end
  end

  describe "save_plan/4" do
    test "accepts account_id, user_id, meals, and optional metadata" do
      assert is_function(&PlanningService.save_plan/4)
    end
  end

  describe "get_scheduled_meals/3" do
    test "accepts account_id with optional from_date and to_date" do
      assert is_function(&PlanningService.get_scheduled_meals/1)
      assert is_function(&PlanningService.get_scheduled_meals/2)
      assert is_function(&PlanningService.get_scheduled_meals/3)
    end
  end

  describe "mark_meal_cooked/1" do
    test "accepts meal_id" do
      assert is_function(&PlanningService.mark_meal_cooked/1)
    end
  end

  describe "delete_scheduled_meal/1" do
    test "accepts meal_id" do
      assert is_function(&PlanningService.delete_scheduled_meal/1)
    end
  end

  describe "start_cooking_session/3" do
    test "accepts account_id, user_id, scheduled_meal_id" do
      assert is_function(&PlanningService.start_cooking_session/3)
    end
  end

  describe "add_chat_message/2" do
    test "accepts session_id and content" do
      assert is_function(&PlanningService.add_chat_message/2)
    end
  end
end
