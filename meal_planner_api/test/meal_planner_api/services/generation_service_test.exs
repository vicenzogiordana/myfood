defmodule MealPlannerApi.Services.GenerationServiceTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Services.GenerationService

  describe "build_constraints/2" do
    test "with nil payload, returns profile defaults" do
      profile = %{protein_g_per_meal: 30, default_exclusions: ["maní"], excluded_recipe_ids: []}
      result = GenerationService.build_constraints(profile, nil)
      assert result.protein_g_per_meal == 30
      assert "maní" in result.excluded_ingredients
    end

    test "with payload, overrides profile values" do
      profile = %{protein_g_per_meal: 25, default_exclusions: []}
      payload = %{"protein_g" => 50, "budget_cents" => 3000}
      result = GenerationService.build_constraints(profile, payload)
      assert result.protein_g_per_meal == 50
      assert result.budget_cents == 3000
    end

    test "with nil profile, uses sensible defaults" do
      result = GenerationService.build_constraints(%{}, nil)
      assert result.protein_g_per_meal == 25
      assert result.budget_cents == 10_000
    end
  end

  describe "validate_constraints/1" do
    test "valid constraints return :ok" do
      assert GenerationService.validate_constraints(%{
               protein_g_per_meal: 30,
               budget_cents: 5000,
               max_calories: 600
             }) == :ok
    end

    test "negative protein returns error" do
      assert match?(
               {:error, :invalid_constraints, _},
               GenerationService.validate_constraints(%{
                 protein_g_per_meal: -5,
                 budget_cents: 5000,
                 max_calories: 600
               })
             )
    end

    test "protein over 200 returns error" do
      assert match?(
               {:error, :invalid_constraints, _},
               GenerationService.validate_constraints(%{
                 protein_g_per_meal: 300,
                 budget_cents: 5000,
                 max_calories: 600
               })
             )
    end

    test "budget over 100000 returns error" do
      assert match?(
               {:error, :invalid_constraints, _},
               GenerationService.validate_constraints(%{
                 protein_g_per_meal: 30,
                 budget_cents: 200_000,
                 max_calories: 600
               })
             )
    end
  end

  describe "slot_key/2" do
    test "formats date and slot as YYYY-MM-DD_slot" do
      assert GenerationService.slot_key("2026-06-03", :lunch) == "2026-06-03_lunch"
    end
  end

  describe "parse_slot_key/1" do
    test "parses slot key back to date and atom slot" do
      {date, slot} = GenerationService.parse_slot_key("2026-06-03_lunch")
      assert date == "2026-06-03"
      assert slot == :lunch
    end
  end

  describe "parse_modification/1" do
    test "detects slot change intent" do
      assert match?(
               {:ok, %{change_type: :change_recipe}},
               GenerationService.parse_modification("cambia el almuerzo 2026-06-04")
             )
    end

    test "detects ingredient removal intent" do
      assert match?(
               {:ok, %{change_type: :remove_ingredient}},
               GenerationService.parse_modification("saca el pollo")
             )
    end

    test "detects price optimization intent" do
      assert match?(
               {:ok, %{change_type: :lower_price}},
               GenerationService.parse_modification("algo más barato")
             )
    end

    test "detects protein increase intent" do
      assert match?(
               {:ok, %{change_type: :higher_protein}},
               GenerationService.parse_modification("más proteína")
             )
    end

    test "unknown message returns error" do
      assert GenerationService.parse_modification("hola qué tal") ==
               {:error, :invalid_modification}
    end
  end

  describe "build_proposal_json/1" do
    test "builds proposal with slots and timestamp" do
      slots = [
        %{
          "date" => "2026-06-03",
          "slot" => :lunch,
          "recipe_id" => "r1",
          "recipe_name" => "Pollo",
          "price_cents" => 1200
        }
      ]

      result = GenerationService.build_proposal_json(slots)
      assert is_list(result.slots)
      assert result.generated_at != nil
    end
  end

  describe "parse_shopping_items/1" do
    test "handles nil input" do
      assert GenerationService.parse_shopping_items(nil) == []
    end

    test "parses shopping items from map" do
      items = %{
        "item1" => %{"name" => "pollo", "quantity" => 2, "unit" => "kg", "price_cents" => 1500}
      }

      result = GenerationService.parse_shopping_items(items)
      assert length(result) == 1
      assert hd(result).ingredient_name == "pollo"
    end
  end
end
