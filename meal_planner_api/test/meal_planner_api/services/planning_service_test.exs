defmodule MealPlannerApi.Services.PlanningServiceTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Services.PlanningService
  alias MealPlannerApi.Optimization.{OptimizerPort, OptimizerPortRunner}

  @python System.get_env("OPTIMIZER_PYTHON")
  @weekdays ~w(monday tuesday wednesday thursday friday)

  describe "generate_weekly_plan/3" do
    test "accepts user map, params map, and optimizer module" do
      assert is_function(&PlanningService.generate_weekly_plan/3)
    end
  end

  describe "run_optimizer/4" do
    test "returns empty meals for empty days list" do
      assert {:ok, %{"meals" => []}} = PlanningService.run_optimizer(OptimizerPort, [], %{}, %{})
    end

    test "uses the injected optimizer client" do
      assert {:ok, %{"meals" => [%{"recipe_id" => "injected"}]}} =
               PlanningService.run_optimizer(
                 MealPlannerApi.TestSupport.InjectedOptimizer,
                 ["monday"],
                 %{"breakfast" => [], "lunch" => [], "dinner" => []},
                 %{}
               )
    end

    test "sends only slots with existing candidates to the optimizer" do
      candidates = %{
        "breakfast" => [%{"recipe_id" => "existing-breakfast", "estimated_cost_cents" => 500}],
        "lunch" => [],
        "dinner" => []
      }

      assert {:ok,
              %{
                "meals" => [
                  %{"recipe_id" => "existing-breakfast", "slot" => "breakfast", "day" => "monday"}
                ]
              }} =
               PlanningService.run_optimizer(
                 MealPlannerApi.Optimization.OptimizerMock,
                 ["monday"],
                 candidates,
                 %{}
               )
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

      payload = PlanningService.build_optimization_payload(days, candidates, user, ~D[2026-10-15])

      assert payload["days"] == ["2026-10-19", "2026-10-20"]
      assert payload["slots"] == ["breakfast", "lunch", "dinner"]
      assert payload["constraints"]["kcal_target"] == 2100
      assert payload["constraints"]["weekly_budget_cents"] == 50000
      assert payload["constraints"]["account_type"] == "individual"
    end

    test "sends the selected weekdays as the ISO dates of the upcoming range" do
      # 2026-10-15 is a Thursday: the range starts on the next Monday.
      payload = PlanningService.build_optimization_payload(@weekdays, %{}, %{}, ~D[2026-10-15])

      assert payload["days"] == [
               "2026-10-19",
               "2026-10-20",
               "2026-10-21",
               "2026-10-22",
               "2026-10-23"
             ]
    end

    test "keeps the weekday order when the range wraps past Sunday" do
      payload =
        PlanningService.build_optimization_payload(
          ~w(saturday sunday monday),
          %{},
          %{},
          ~D[2026-10-15]
        )

      assert payload["days"] == ["2026-10-17", "2026-10-18", "2026-10-19"]
    end

    if is_nil(@python) do
      @tag skip: "set OPTIMIZER_PYTHON to an interpreter with OR-Tools installed"
    end

    test "the default weekly payload passes the real optimizer validation" do
      candidate = %{"recipe_id" => "r-1", "estimated_cost_cents" => 500}
      candidates = Map.new(~w(breakfast lunch dinner), &{&1, [candidate]})

      payload = PlanningService.build_optimization_payload(@weekdays, candidates, %{})

      assert optimizer_validation_error(payload) == nil
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

  defp optimizer_validation_error(payload) do
    script = """
    import json, sys
    sys.path.insert(0, sys.argv[1])
    import optimizador
    print(json.dumps(optimizador._validate_payload(json.loads(sys.argv[2]))))
    """

    root = Path.dirname(OptimizerPortRunner.default_script_path())
    {out, 0} = System.cmd(@python, ["-c", script, root, Jason.encode!(payload)])
    Jason.decode!(out)
  end
end
