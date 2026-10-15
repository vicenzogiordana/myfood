defmodule MealPlannerApi.Optimization.ContractTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Optimization.Contract

  describe "nutrition_bounds/1" do
    test "turns the Household Nutrition Goal into the optimizer's daily bounds" do
      goal = %{
        account_id: Ecto.UUID.generate(),
        period: "daily",
        per: "standard_portion",
        calories: %{min: 1_800, max: 2_200},
        protein_g: %{min: 90, max: 140},
        carbs_g: %{min: 180, max: 260},
        fat_g: %{min: 50, max: 80},
        updated_at: DateTime.utc_now()
      }

      assert Contract.nutrition_bounds(goal) == %{
               "calories" => %{"min" => 1_800, "max" => 2_200},
               "protein_g" => %{"min" => 90, "max" => 140},
               "carbs_g" => %{"min" => 180, "max" => 260},
               "fat_g" => %{"min" => 50, "max" => 80}
             }
    end

    test "a Household without a Nutrition Goal sends no nutrition bounds" do
      assert Contract.nutrition_bounds(nil) == nil
    end
  end

  describe "interpret/1 solutions" do
    test "returns the plan, its exact Deviations in priority order and the optimality" do
      reply =
        {:ok,
         %{
           "meals" => [%{"day" => "2026-09-07", "slot" => "lunch", "recipe_id" => "r-1"}],
           "deviations" => [
             %{
               "goal" => "budget",
               "priority" => 1,
               "direction" => "above_max",
               "bound" => 100,
               "actual" => 250,
               "amount" => 150
             },
             %{
               "goal" => "calories",
               "priority" => 2,
               "day" => "2026-09-07",
               "direction" => "below_min",
               "bound" => 1_000,
               "actual" => 400,
               "amount" => 600
             }
           ],
           "optimality" => "optimal"
         }}

      assert {:ok, plan} = Contract.interpret(reply)

      assert plan.meals == [%{date: ~D[2026-09-07], slot: "lunch", recipe_id: "r-1"}]
      assert plan.optimality == :optimal

      assert plan.deviations == [
               %{
                 goal: :budget,
                 priority: 1,
                 day: nil,
                 direction: :above_max,
                 bound: 100,
                 actual: 250,
                 amount: 150
               },
               %{
                 goal: :calories,
                 priority: 2,
                 day: ~D[2026-09-07],
                 direction: :below_min,
                 bound: 1_000,
                 actual: 400,
                 amount: 600
               }
             ]
    end

    test "a feasible but unproven plan is kept and disclosed" do
      assert {:ok, %{optimality: :feasible, deviations: []}} =
               Contract.interpret(
                 {:ok, %{"meals" => [], "deviations" => [], "optimality" => "feasible"}}
               )
    end

    test "a result without the v2 fields is rejected rather than read as Deviation-free" do
      assert {:error, :invalid_optimizer_response} =
               Contract.interpret({:ok, %{"meals" => []}})
    end

    test "an unknown goal or optimality is rejected" do
      deviation = %{
        "goal" => "sodium",
        "priority" => 3,
        "direction" => "above_max",
        "bound" => 1,
        "actual" => 2,
        "amount" => 1
      }

      assert {:error, :invalid_optimizer_response} =
               Contract.interpret(
                 {:ok, %{"meals" => [], "deviations" => [deviation], "optimality" => "optimal"}}
               )

      assert {:error, :invalid_optimizer_response} =
               Contract.interpret(
                 {:ok, %{"meals" => [], "deviations" => [], "optimality" => "probably"}}
               )
    end
  end

  describe "interpret/1 failures" do
    test "infeasibility carries every named cause" do
      details = %{
        "causes" => [
          %{"cause" => "restriction", "slot" => "lunch"},
          %{"cause" => "excluded_recipe", "slot" => "lunch"},
          %{"cause" => "coverage", "slot" => "dinner"}
        ]
      }

      assert Contract.interpret({:error, :infeasible, details}) ==
               {:infeasible,
                [
                  %{cause: :restriction, slot: "lunch"},
                  %{cause: :excluded_recipe, slot: "lunch"},
                  %{cause: :coverage, slot: "dinner"}
                ]}

      assert Contract.interpret({:error, "infeasible", details}) ==
               Contract.interpret({:error, :infeasible, details})
    end

    test "a solver time limit is inconclusive, never infeasible" do
      assert Contract.interpret({:error, "inconclusive", %{"reason" => "time_limit"}}) ==
               {:inconclusive, :time_limit}

      assert Contract.interpret({:error, :inconclusive, %{"reason" => "time_limit"}}) ==
               {:inconclusive, :time_limit}
    end

    test "a caller-side deadline is inconclusive too" do
      assert Contract.interpret({:error, :optimizer_timeout, %{}}) == {:inconclusive, :deadline}
      assert Contract.interpret({:error, :optimizer_timeout}) == {:inconclusive, :deadline}
    end

    test "other failures stay typed errors" do
      assert Contract.interpret({:error, :optimizer_unavailable, %{}}) ==
               {:error, :optimizer_unavailable}

      assert Contract.interpret({:error, "invalid_budget", %{}}) == {:error, :optimizer_error}
    end
  end
end
