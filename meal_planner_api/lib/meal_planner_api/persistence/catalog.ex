defmodule MealPlannerApi.Persistence.Catalog do
  @moduledoc "Persistence helpers for ingredients, recipes and cost cache."

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Catalog.{
    Ingredient,
    Recipe,
    RecipeDailyCost,
    RecipeIngredient,
    RecipeStep
  }

  alias MealPlannerApi.Persistence.Shopping.RecipePrice

  def create_ingredient(attrs), do: %Ingredient{} |> Ingredient.changeset(attrs) |> Repo.insert()

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

  def list_ingredients, do: Repo.all(Ingredient)

  def create_recipe(attrs), do: %Recipe{} |> Recipe.changeset(attrs) |> Repo.insert()

  def get_recipe!(id), do: Repo.get!(Recipe, id)

  def get_recipe_with_details!(id) do
    Recipe
    |> Repo.get!(id)
    |> Repo.preload([:recipe_steps, :recipe_ingredients, :daily_costs])
  end

  def add_recipe_step(attrs), do: %RecipeStep{} |> RecipeStep.changeset(attrs) |> Repo.insert()

  def add_recipe_ingredient(attrs),
    do: %RecipeIngredient{} |> RecipeIngredient.changeset(attrs) |> Repo.insert()

  def upsert_recipe_daily_cost(attrs) do
    %RecipeDailyCost{}
    |> RecipeDailyCost.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:total_cents_ars, :updated_at]},
      conflict_target: [:recipe_id, :supermarket_id, :date]
    )
  end

  def recipes_for_slot(account_id, slot) do
    slot_str = if is_atom(slot), do: Atom.to_string(slot), else: slot

    from(r in Recipe,
      where: is_nil(r.account_id) or r.account_id == ^account_id,
      where: ^slot_str in r.suitable_for_slots
    )
    |> Repo.all()
  end

  @doc """
  Lists all recipes with their recipe_prices and ingredients preloaded.
  Used by PriceService to build the optimizer slot list.
  """
  @spec list_recipes_with_prices_and_ingredients() :: [Recipe.t()]
  def list_recipes_with_prices_and_ingredients do
    from(r in Recipe,
      left_join: rp in RecipePrice,
      on: rp.recipe_id == r.id,
      left_join: ri in assoc(r, :recipe_ingredients),
      left_join: i in assoc(ri, :ingredient),
      preload: [recipe_price: rp, recipe_ingredients: {ri, ingredient: i}]
    )
    |> Repo.all()
  end
end
