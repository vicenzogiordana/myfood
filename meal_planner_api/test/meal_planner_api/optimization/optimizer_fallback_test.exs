defmodule MealPlannerApi.Optimization.OptimizerFallbackTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Optimization.OptimizerFallback

  describe "select_weekly_menu/1" do
    test "returns a valid plan with all days and slots" do
      payload = build_payload(7)

      assert {:ok, %{meals: meals}} = OptimizerFallback.select_weekly_menu(payload)
      # 7 days × 3 slots
      assert length(meals) == 21
    end

    test "every meal has day, slot, recipe_id" do
      payload = build_payload(7)

      assert {:ok, %{meals: meals}} = OptimizerFallback.select_weekly_menu(payload)

      for meal <- meals do
        assert is_binary(meal["day"])
        assert is_binary(meal["slot"])
        assert is_binary(meal["recipe_id"]) or is_nil(meal["recipe_id"])
      end
    end

    test "picks cheapest recipe per slot" do
      payload = %{
        days: ["monday"],
        slots: ["breakfast", "lunch", "dinner"],
        constraints: %{},
        candidates_by_slot: %{
          "breakfast" => [
            %{"recipe_id" => "r1", "estimated_cost_cents" => 500},
            # cheapest
            %{"recipe_id" => "r2", "estimated_cost_cents" => 300}
          ],
          "lunch" => [
            %{"recipe_id" => "r3", "estimated_cost_cents" => 700},
            # cheapest
            %{"recipe_id" => "r4", "estimated_cost_cents" => 400}
          ],
          "dinner" => [
            # only option
            %{"recipe_id" => "r5", "estimated_cost_cents" => 900}
          ]
        }
      }

      assert {:ok, %{meals: meals}} = OptimizerFallback.select_weekly_menu(payload)

      breakfast = Enum.find(meals, &(&1["slot"] == "breakfast"))
      assert breakfast["recipe_id"] == "r2"

      lunch = Enum.find(meals, &(&1["slot"] == "lunch"))
      assert lunch["recipe_id"] == "r4"

      dinner = Enum.find(meals, &(&1["slot"] == "dinner"))
      assert dinner["recipe_id"] == "r5"
    end

    test "handles different day counts" do
      payload = build_payload(3)

      assert {:ok, %{meals: meals}} = OptimizerFallback.select_weekly_menu(payload)
      # 3 days × 3 slots
      assert length(meals) == 9
    end

    test "ignores candidates with nil recipe_id" do
      payload = %{
        days: ["monday"],
        slots: ["breakfast", "lunch", "dinner"],
        constraints: %{},
        candidates_by_slot: %{
          "breakfast" => [
            %{"recipe_id" => nil, "estimated_cost_cents" => 100},
            %{"recipe_id" => "r1", "estimated_cost_cents" => 500}
          ],
          "lunch" => [],
          "dinner" => []
        }
      }

      assert {:ok, %{meals: meals}} = OptimizerFallback.select_weekly_menu(payload)

      breakfast = Enum.find(meals, &(&1["slot"] == "breakfast"))
      assert breakfast["recipe_id"] == "r1"

      lunch = Enum.find(meals, &(&1["slot"] == "lunch"))
      assert lunch["recipe_id"] == nil
    end

    test "returns nil recipe_id when no candidates available" do
      payload = %{
        days: ["monday"],
        slots: ["breakfast", "lunch", "dinner"],
        constraints: %{},
        candidates_by_slot: %{}
      }

      assert {:ok, %{meals: meals}} = OptimizerFallback.select_weekly_menu(payload)
      # 1 day × 3 slots
      assert length(meals) == 3
      assert Enum.all?(meals, &is_nil(&1["recipe_id"]))
    end
  end

  describe "health_check/0" do
    test "returns :ok" do
      assert OptimizerFallback.health_check() == :ok
    end
  end

  # ---

  defp build_payload(days_count) do
    days = Enum.take(~w(monday tuesday wednesday thursday friday saturday sunday), days_count)

    %{
      days: days,
      slots: ["breakfast", "lunch", "dinner"],
      constraints: %{
        kcal_target: 2100,
        weekly_budget_cents: 50_000,
        account_type: "individual",
        subscription_tier: "free",
        inventory_items: [],
        macro_bounds: %{
          protein_g: %{min: 50.0, max: 200.0},
          carbs_g: %{min: 100.0, max: 400.0},
          fat_g: %{min: 40.0, max: 150.0}
        }
      },
      candidates_by_slot: %{
        "breakfast" => build_candidates("breakfast"),
        "lunch" => build_candidates("lunch"),
        "dinner" => build_candidates("dinner")
      }
    }
  end

  defp build_candidates(slot) do
    [
      %{
        "recipe_id" => "recipe-#{slot}-1",
        "slot" => slot,
        "label" => "#{slot} option 1",
        "kcal" => 300,
        "estimated_cost_cents" => 400,
        "inventory_hit_count" => 0,
        "protein_g_per_serving" => 10.0,
        "carbs_g_per_serving" => 40.0,
        "fat_g_per_serving" => 8.0
      },
      %{
        "recipe_id" => "recipe-#{slot}-2",
        "slot" => slot,
        "label" => "#{slot} option 2",
        "kcal" => 450,
        "estimated_cost_cents" => 600,
        "inventory_hit_count" => 1,
        "protein_g_per_serving" => 15.0,
        "carbs_g_per_serving" => 50.0,
        "fat_g_per_serving" => 12.0
      }
    ]
  end
end
