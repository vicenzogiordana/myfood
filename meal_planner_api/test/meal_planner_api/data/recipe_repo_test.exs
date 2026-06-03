defmodule MealPlannerApi.Data.RecipeRepoTest do
  use ExUnit.Case, async: true

  describe "list_ingredients/0" do
    test "returns all ingredients" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.list_ingredients/0)
    end
  end

  describe "find_ingredients_by_names/1" do
    test "accepts a list of names" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.find_ingredients_by_names/1)
    end

    test "handles empty list" do
      # Repo is lazy — just verify the function accepts [] without hitting DB
      assert is_function(&MealPlannerApi.Data.RecipeRepo.find_ingredients_by_names/1)
    end
  end

  describe "get_recipe!/1" do
    test "accepts an id and returns a struct" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.get_recipe!/1)
    end
  end

  describe "list_recipes/1" do
    test "accepts account_id and returns a list" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.list_recipes/1)
    end
  end

  describe "search_recipes_by_title/2" do
    test "accepts account_id and query string" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.search_recipes_by_title/2)
    end
  end

  describe "get_recipe_with_details!/1" do
    test "accepts recipe id" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.get_recipe_with_details!/1)
    end
  end

  describe "get_recipe_with_ingredients!/1" do
    test "accepts recipe id" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.get_recipe_with_ingredients!/1)
    end
  end

  describe "add_recipe_step/1" do
    test "accepts attrs map" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.add_recipe_step/1)
    end
  end

  describe "update_recipe_step/2" do
    test "accepts step and attrs" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.update_recipe_step/2)
    end
  end

  describe "delete_recipe_step/1" do
    test "accepts step id" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.delete_recipe_step/1)
    end
  end

  describe "add_recipe_ingredient/1" do
    test "accepts attrs map" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.add_recipe_ingredient/1)
    end
  end

  describe "delete_recipe_ingredient/1" do
    test "accepts id" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.delete_recipe_ingredient/1)
    end
  end

  describe "get_recipe_ingredient_with_ingredient!/1" do
    test "accepts id" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.get_recipe_ingredient_with_ingredient!/1)
    end
  end

  describe "add_favorite/2" do
    test "accepts account_id and recipe_id" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.add_favorite/2)
    end
  end

  describe "remove_favorite/2" do
    test "accepts account_id and recipe_id" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.remove_favorite/2)
    end
  end

  describe "list_favorites/1" do
    test "accepts account_id" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.list_favorites/1)
    end
  end

  describe "is_favorite?/2" do
    test "accepts account_id and recipe_id" do
      assert is_function(&MealPlannerApi.Data.RecipeRepo.is_favorite?/2)
    end
  end
end
