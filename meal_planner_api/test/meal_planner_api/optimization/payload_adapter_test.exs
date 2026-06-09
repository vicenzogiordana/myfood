defmodule MealPlannerApi.Optimization.PayloadAdapterTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Optimization.PayloadAdapter

  describe "build_optimizer_payload/3" do
    test "translates single slot to correct output structure" do
      slots = [
        %{
          date: "2026-06-03",
          slot: :lunch,
          available_recipe_ids: ["1", "2"],
          constraints: %{
            budget_cents: 5000,
            protein_g: 30,
            max_calories: 800
          }
        }
      ]

      recipe_prices = %{"1" => 12.50, "2" => 9.50}

      recipe_macros = %{
        "1" => %{protein_g: 25, calories: 450, carbs_g: 30},
        "2" => %{protein_g: 20, calories: 350, carbs_g: 25}
      }

      result = PayloadAdapter.build_optimizer_payload(slots, recipe_prices, recipe_macros)

      assert result[:days] == ["2026-06-03"]
      assert result[:slots] == ["lunch"]
      assert result[:constraints][:weekly_budget_cents] == 5000
      assert result[:candidates_by_slot]["lunch"] |> length() == 2
    end

    test "deduplicates days from multiple slots" do
      slots = [
        %{
          date: "2026-06-03",
          slot: :lunch,
          available_recipe_ids: ["1"],
          constraints: %{budget_cents: 5000}
        },
        %{
          date: "2026-06-03",
          slot: :dinner,
          available_recipe_ids: ["2"],
          constraints: %{budget_cents: 5000}
        },
        %{
          date: "2026-06-04",
          slot: :lunch,
          available_recipe_ids: ["1"],
          constraints: %{budget_cents: 5000}
        }
      ]

      result = PayloadAdapter.build_optimizer_payload(slots, %{}, %{})

      assert length(result[:days]) == 2
      assert "2026-06-03" in result[:days]
      assert "2026-06-04" in result[:days]
    end

    test "builds slots list from unique slot types" do
      slots = [
        %{
          date: "2026-06-03",
          slot: :lunch,
          available_recipe_ids: ["1"],
          constraints: %{budget_cents: 5000}
        },
        %{
          date: "2026-06-03",
          slot: :breakfast,
          available_recipe_ids: ["2"],
          constraints: %{budget_cents: 5000}
        }
      ]

      result = PayloadAdapter.build_optimizer_payload(slots, %{}, %{})

      assert length(result[:slots]) == 2
      assert "lunch" in result[:slots]
      assert "breakfast" in result[:slots]
    end

    test "computes weekly_budget_cents by summing per-slot budgets" do
      slots = [
        %{
          date: "2026-06-03",
          slot: :lunch,
          available_recipe_ids: ["1"],
          constraints: %{budget_cents: 5000}
        },
        %{
          date: "2026-06-03",
          slot: :dinner,
          available_recipe_ids: ["2"],
          constraints: %{budget_cents: 6000}
        }
      ]

      result = PayloadAdapter.build_optimizer_payload(slots, %{}, %{})

      assert result[:constraints][:weekly_budget_cents] == 11000
    end

    test "computes macro_bounds from constraints with buffer" do
      slots = [
        %{
          date: "2026-06-03",
          slot: :lunch,
          available_recipe_ids: ["1"],
          constraints: %{protein_g: 30}
        },
        %{
          date: "2026-06-04",
          slot: :lunch,
          available_recipe_ids: ["2"],
          constraints: %{protein_g: 30}
        }
      ]

      result = PayloadAdapter.build_optimizer_payload(slots, %{}, %{})

      protein_bounds = result[:constraints][:macro_bounds][:protein_g]
      assert protein_bounds[:min] == 60 * 0.7
      assert protein_bounds[:max] == 60 * 1.3
    end

    test "builds candidates_by_slot with full recipe data" do
      slots = [
        %{
          date: "2026-06-03",
          slot: :lunch,
          available_recipe_ids: ["1", "2"],
          constraints: %{protein_g: 30}
        }
      ]

      recipe_prices = %{"1" => 12.50, "2" => 9.75}

      recipe_macros = %{
        "1" => %{protein_g: 25, calories: 450, carbs_g: 30, fat_g: 10},
        "2" => %{protein_g: 20, calories: 350, carbs_g: 25, fat_g: 8}
      }

      result = PayloadAdapter.build_optimizer_payload(slots, recipe_prices, recipe_macros)

      candidates = result[:candidates_by_slot]["lunch"]
      assert length(candidates) == 2

      candidate_1 = Enum.find(candidates, fn c -> c[:recipe_id] == "1" end)
      assert candidate_1[:estimated_cost_cents] == 1250
      assert candidate_1[:protein_g_per_serving] == 25
    end

    test "handles missing recipe data with defaults" do
      slots = [
        %{
          date: "2026-06-03",
          slot: :lunch,
          available_recipe_ids: ["99"],
          constraints: %{protein_g: 30}
        }
      ]

      result = PayloadAdapter.build_optimizer_payload(slots, %{}, %{})

      candidate = result[:candidates_by_slot]["lunch"] |> List.first()
      assert candidate[:estimated_cost_cents] == 0
      # default
      assert candidate[:protein_g_per_serving] == 25
    end
  end

  describe "translate_response/2" do
    test "enriches optimizer response with recipe data" do
      optimizer_result =
        {:ok,
         %{
           meals: [
             %{day: "2026-06-03", slot: "lunch", recipe_id: "1"},
             %{day: "2026-06-03", slot: "dinner", recipe_id: "2"}
           ]
         }}

      recipe_data = %{
        "1" => %{
          name: "Pollo al horno",
          price_cents: 1250,
          protein_g: 25,
          calories: 450,
          carbs_g: 30
        },
        "2" => %{
          name: "Ensalada César",
          price_cents: 850,
          protein_g: 15,
          calories: 300,
          carbs_g: 20
        }
      }

      assert {:ok, result} = PayloadAdapter.translate_response(optimizer_result, recipe_data)

      assert length(result) == 2

      first = Enum.find(result, fn r -> r[:recipe_id] == "1" end)
      assert first[:date] == "2026-06-03"
      assert first[:slot] == "lunch"
      assert first[:recipe_name] == "Pollo al horno"
      assert first[:price_cents] == 1250
      assert first[:macros][:protein_g] == 25
    end

    test "handles missing recipe data with defaults" do
      optimizer_result =
        {:ok,
         %{
           meals: [
             %{day: "2026-06-03", slot: "lunch", recipe_id: "99"}
           ]
         }}

      recipe_data = %{}

      assert {:ok, result} = PayloadAdapter.translate_response(optimizer_result, recipe_data)

      first = List.first(result)
      assert first[:recipe_name] == "Unknown Recipe"
      assert first[:price_cents] == 0
      assert first[:macros][:protein_g] == 0
    end

    test "propagates error from optimizer" do
      optimizer_result = {:error, :no_valid_plan}
      recipe_data = %{}

      result = PayloadAdapter.translate_response(optimizer_result, recipe_data)

      assert result == {:error, :no_valid_plan}
    end
  end
end
