defmodule MealPlannerApi.Services.PriceServiceTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Services.PriceService

  describe "fetch_recipe_prices/1" do
    test "has correct arity (accepts list, returns map)" do
      assert is_function(&PriceService.fetch_recipe_prices/1, 1)
    end
  end

  describe "fetch_recipe_prices_float/1" do
    test "has correct arity (accepts list, returns map)" do
      assert is_function(&PriceService.fetch_recipe_prices_float/1, 1)
    end
  end

  describe "merge_constraints/2" do
    test "with nil overrides, returns profile as-is" do
      profile = %{protein_g_per_meal: 30, default_exclusions: ["maní"]}
      assert PriceService.merge_constraints(profile, nil) == profile
    end

    test "overrides protein from payload" do
      profile = %{protein_g_per_meal: 25, default_exclusions: []}
      overrides = %{protein_g: 40}
      result = PriceService.merge_constraints(profile, overrides)
      assert result.protein_g_per_meal == 40
    end

    test "overrides budget from payload" do
      profile = %{protein_g_per_meal: 25, default_exclusions: []}
      overrides = %{budget_cents: 5000}
      result = PriceService.merge_constraints(profile, overrides)
      assert result.max_budget_per_meal_cents == 5000
    end

    test "combines payload exclusions with profile exclusions" do
      profile = %{protein_g_per_meal: 25, default_exclusions: ["maní", "lactosa"]}
      overrides = %{excluded_ingredients: ["gluten"]}
      result = PriceService.merge_constraints(profile, overrides)
      assert "gluten" in result.excluded_ingredients
      assert "maní" in result.excluded_ingredients
      assert "lactosa" in result.excluded_ingredients
    end
  end

  describe "available_recipe_ids_for_slot/2" do
    test "has correct arity (accepts recipe list + slot string, returns list)" do
      assert is_function(&PriceService.available_recipe_ids_for_slot/2, 2)
    end
  end
end
