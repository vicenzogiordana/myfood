defmodule MealPlannerApi.Data.RecipeRepo do
  @moduledoc """
  Pure data access for recipes, ingredients, and their relationships.

  No business logic. No orchestration. Just queries and persistence.
  """

  import Ecto.Query, warn: false
  alias MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Catalog.{
    FavoriteRecipe,
    Ingredient,
    Recipe,
    RecipeIngredient,
    RecipeStep
  }

  # -------------------------------------------------------------------------
  # Ingredients
  # -------------------------------------------------------------------------

  @spec list_ingredients() :: [Ingredient.t()]
  def list_ingredients, do: Repo.all(Ingredient)

  @spec create_ingredient(map()) :: {:ok, Ingredient.t()} | {:error, Ecto.Changeset.t()}
  def create_ingredient(attrs),
    do: %Ingredient{} |> Ingredient.changeset(attrs) |> Repo.insert()

  @spec upsert_ingredient_by_name(map()) :: {:ok, Ingredient.t()} | {:error, Ecto.Changeset.t()}
  def upsert_ingredient_by_name(attrs) do
    %Ingredient{}
    |> Ingredient.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :category,
           :sku_reference,
           :calories_per_100,
           :protein_g_per_100,
           :carbs_g_per_100,
           :fat_g_per_100,
           :updated_at
         ]},
      conflict_target: [:name]
    )
  end

  @spec get_ingredient!(pos_integer()) :: Ingredient.t()
  def get_ingredient!(id), do: Repo.get!(Ingredient, id)

  @spec find_ingredients_by_names([String.t()]) :: [Ingredient.t()]
  def find_ingredients_by_names(names) when is_list(names) do
    from(i in Ingredient, where: i.name in ^names) |> Repo.all()
  end

  # -------------------------------------------------------------------------
  # Recipes
  # -------------------------------------------------------------------------

  @spec get_recipe!(pos_integer()) :: Recipe.t()
  def get_recipe!(id), do: Repo.get!(Recipe, id)

  @spec create_recipe(map()) :: {:ok, Recipe.t()} | {:error, Ecto.Changeset.t()}
  def create_recipe(attrs), do: %Recipe{} |> Recipe.changeset(attrs) |> Repo.insert()

  @spec list_recipes(account_id :: pos_integer()) :: [Recipe.t()]
  def list_recipes(nil), do: Repo.all(Recipe)

  def list_recipes(account_id) do
    from(r in Recipe, where: r.account_id == ^account_id, order_by: [asc: r.name])
    |> Repo.all()
  end

  @spec search_recipes_by_title(account_id :: pos_integer(), String.t()) :: [Recipe.t()]
  def search_recipes_by_title(account_id, query) do
    pattern = "%#{query}%"

    from(r in Recipe,
      where: r.account_id == ^account_id and ilike(r.name, ^pattern),
      order_by: [asc: r.name]
    )
    |> Repo.all()
  end

  @spec get_recipe_with_details!(pos_integer()) :: Recipe.t()
  def get_recipe_with_details!(id) do
    Recipe
    |> Repo.get!(id)
    |> Repo.preload([:recipe_steps, :recipe_ingredients, :daily_costs])
  end

  @spec get_recipe_with_ingredients!(pos_integer()) :: Recipe.t()
  def get_recipe_with_ingredients!(id) do
    Recipe
    |> Repo.get!(id)
    |> Repo.preload(recipe_ingredients: [:ingredient])
  end

  # -------------------------------------------------------------------------
  # Recipe steps
  # -------------------------------------------------------------------------

  @spec add_recipe_step(map()) :: {:ok, RecipeStep.t()} | {:error, Ecto.Changeset.t()}
  def add_recipe_step(attrs),
    do: %RecipeStep{} |> RecipeStep.changeset(attrs) |> Repo.insert()

  @spec update_recipe_step(RecipeStep.t(), map()) ::
          {:ok, RecipeStep.t()} | {:error, Ecto.Changeset.t()}
  def update_recipe_step(step, attrs), do: step |> RecipeStep.changeset(attrs) |> Repo.update()

  @spec delete_recipe_step(pos_integer()) :: :ok
  def delete_recipe_step(id) do
    Repo.delete!(Repo.get!(RecipeStep, id))
    :ok
  end

  # -------------------------------------------------------------------------
  # Recipe ingredients (associations)
  # -------------------------------------------------------------------------

  @spec add_recipe_ingredient(map()) :: {:ok, RecipeIngredient.t()} | {:error, Ecto.Changeset.t()}
  def add_recipe_ingredient(attrs),
    do: %RecipeIngredient{} |> RecipeIngredient.changeset(attrs) |> Repo.insert()

  @doc """
  Returns the recipe_ingredients for the given recipe ids grouped by recipe id.

  Shape: `%{recipe_id => [%{ingredient_id, unit, quantity_milli}]}`. Recipe ids
  with no `recipe_ingredients` are absent from the map (callers default via
  `Map.get(map, id, [])`). Feeds `GenerationService.build_cart_lines/2`.
  """
  @spec list_ingredients_for_recipes([binary()]) :: %{binary() => [map()]}
  def list_ingredients_for_recipes(recipe_ids) when is_list(recipe_ids) do
    from(ri in RecipeIngredient,
      where: ri.recipe_id in ^recipe_ids,
      select: %{
        recipe_id: ri.recipe_id,
        ingredient_id: ri.ingredient_id,
        unit: ri.unit,
        quantity_milli: ri.quantity_milli
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.recipe_id, &Map.delete(&1, :recipe_id))
  end

  @spec delete_recipe_ingredient(pos_integer()) :: :ok
  def delete_recipe_ingredient(id) do
    Repo.delete!(Repo.get!(RecipeIngredient, id))
    :ok
  end

  @spec get_recipe_ingredient_with_ingredient!(pos_integer()) :: RecipeIngredient.t()
  def get_recipe_ingredient_with_ingredient!(id) do
    Repo.get!(RecipeIngredient, id) |> Repo.preload(:ingredient)
  end

  # -------------------------------------------------------------------------
  # Favorites
  # -------------------------------------------------------------------------

  @spec add_favorite(pos_integer(), pos_integer()) ::
          {:ok, FavoriteRecipe.t()} | {:error, Ecto.Changeset.t()}
  def add_favorite(account_id, recipe_id) do
    attrs = %{account_id: account_id, recipe_id: recipe_id}
    %FavoriteRecipe{} |> FavoriteRecipe.changeset(attrs) |> Repo.insert()
  end

  @spec remove_favorite(pos_integer(), pos_integer()) :: :ok
  def remove_favorite(account_id, recipe_id) do
    from(f in FavoriteRecipe,
      where: f.account_id == ^account_id and f.recipe_id == ^recipe_id
    )
    |> Repo.delete_all()

    :ok
  end

  @spec list_favorites(pos_integer()) :: [Recipe.t()]
  def list_favorites(account_id) do
    from(f in FavoriteRecipe,
      join: r in assoc(f, :recipe),
      where: f.account_id == ^account_id,
      order_by: [asc: r.name],
      preload: [recipe: :recipe_ingredients]
    )
    |> Repo.all()
    |> Enum.map(& &1.recipe)
  end

  @spec list_by_ids([pos_integer()]) :: [Recipe.t()]
  def list_by_ids(ids) when is_list(ids) do
    from(r in Recipe, where: r.id in ^ids)
    |> Repo.all()
  end

  @doc """
  Returns recipes with their prices preloaded.
  Used by GenerationServer to enrich optimizer responses with recipe names and prices.
  """
  @spec list_by_ids_with_prices([pos_integer()]) :: [Recipe.t()]
  def list_by_ids_with_prices(recipe_ids) when is_list(recipe_ids) do
    from(r in Recipe,
      where: r.id in ^recipe_ids,
      preload: [:recipe_price]
    )
    |> Repo.all()
  end

  @spec is_favorite?(pos_integer(), pos_integer()) :: boolean()
  def is_favorite?(account_id, recipe_id) do
    Repo.exists?(
      from(f in FavoriteRecipe,
        where: f.account_id == ^account_id and f.recipe_id == ^recipe_id
      )
    )
  end

  # -------------------------------------------------------------------------
  # Favorite IDs (for GenerationServer optimization hints)
  # -------------------------------------------------------------------------

  @doc """
  Returns the list of favorite recipe IDs for a given account.
  Used by GenerationServer to inject preferred_recipe_ids into the OR-Tools payload.

  Returns a list of maps with `:id` key, e.g. `[%{id: 1}, %{id: 5}]`.
  """
  @spec list_favorite_ids(pos_integer()) :: [%{id: pos_integer()}]
  def list_favorite_ids(account_id) do
    from(f in FavoriteRecipe,
      where: f.account_id == ^account_id,
      select: %{id: f.recipe_id}
    )
    |> Repo.all()
  end
end
