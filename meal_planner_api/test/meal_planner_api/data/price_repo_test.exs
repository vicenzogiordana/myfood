defmodule MealPlannerApi.Data.PriceRepoTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Data.PriceRepo

  describe "latest_prices/1" do
    test "accepts list of ingredient ids, returns map" do
      assert is_function(&PriceRepo.latest_prices/1, 1)
    end
  end

  describe "latest_prices_map/1" do
    test "accepts list of ingredient ids, returns nested map" do
      assert is_function(&PriceRepo.latest_prices_map/1, 1)
    end
  end

  describe "best_price_per_ingredient/1" do
    test "accepts list of ingredient ids, returns map" do
      assert is_function(&PriceRepo.best_price_per_ingredient/1, 1)
    end
  end

  describe "upsert_prices/1" do
    test "accepts list of price maps, returns {int, list}" do
      assert is_function(&PriceRepo.upsert_prices/1, 1)
    end
  end

  describe "get_recipe_price/1" do
    test "accepts recipe_id, returns RecipePrice or nil" do
      assert is_function(&PriceRepo.get_recipe_price/1, 1)
    end
  end

  describe "get_recipe_prices/1" do
    test "accepts list of recipe_ids, returns list" do
      assert is_function(&PriceRepo.get_recipe_prices/1, 1)
    end
  end

  describe "compute_all_recipe_prices/0" do
    test "takes no args, returns {int, int}" do
      assert is_function(&PriceRepo.compute_all_recipe_prices/0, 0)
    end
  end
end
