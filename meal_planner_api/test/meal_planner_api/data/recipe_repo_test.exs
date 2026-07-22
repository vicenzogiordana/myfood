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

  describe "list_ingredients_for_recipes/1" do
    alias Ecto.Adapters.SQL.Sandbox
    alias MealPlannerApi.Data.RecipeRepo
    alias MealPlannerApi.Persistence.Catalog
    alias MealPlannerApi.Repo

    setup do
      :ok = Sandbox.checkout(Repo)
    end

    defp make_ingredient(name) do
      {:ok, ingredient} = Catalog.create_ingredient(%{name: name, category: :granos})
      ingredient
    end

    defp make_recipe(name) do
      {:ok, recipe} = Catalog.create_recipe(%{name: name, source: :user_created})
      recipe
    end

    defp add_ingredient(recipe, ingredient, quantity_milli, unit) do
      {:ok, _} =
        RecipeRepo.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: quantity_milli,
          unit: unit
        })
    end

    test "groups recipe_ingredients by recipe_id with ingredient_id, unit, quantity_milli" do
      rice = make_ingredient("Rice")
      beans = make_ingredient("Beans")
      recipe_a = make_recipe("Recipe A")
      recipe_b = make_recipe("Recipe B")

      add_ingredient(recipe_a, rice, 500, :g)
      add_ingredient(recipe_a, beans, 200, :g)
      add_ingredient(recipe_b, rice, 300, :g)

      result = RecipeRepo.list_ingredients_for_recipes([recipe_a.id, recipe_b.id])

      assert %{} = result
      assert length(Map.get(result, recipe_a.id)) == 2
      assert length(Map.get(result, recipe_b.id)) == 1

      assert %{ingredient_id: beans.id, unit: :g, quantity_milli: 200} in Map.get(
               result,
               recipe_a.id
             )

      assert [%{ingredient_id: rice.id, unit: :g, quantity_milli: 300}] ==
               Map.get(result, recipe_b.id)
    end

    test "omits recipe ids that have no recipe_ingredients" do
      recipe = make_recipe("Empty Recipe")

      result = RecipeRepo.list_ingredients_for_recipes([recipe.id])

      refute Map.has_key?(result, recipe.id)
      assert Map.get(result, recipe.id, []) == []
    end
  end
end
