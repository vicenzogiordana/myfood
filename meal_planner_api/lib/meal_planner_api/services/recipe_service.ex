defmodule MealPlannerApi.Services.RecipeService do
  @moduledoc """
  Recipe management orchestration.

  Coordinates recipe CRUD, favorites, and search.
  """

  alias MealPlannerApi.Data.RecipeRepo
  alias MealPlannerApi.Persistence.Identity

  # -------------------------------------------------------------------------
  # Recipe CRUD
  # -------------------------------------------------------------------------

  @spec list_recipes(map()) :: {:ok, [map()]} | {:error, term()}
  def list_recipes(user) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        recipes = RecipeRepo.list_recipes(identity.account_id)
        {:ok, Enum.map(recipes, &serialize_recipe/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_recipe(map(), pos_integer()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_recipe(user, recipe_id) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, _identity} ->
        case RecipeRepo.get_recipe_with_details!(recipe_id) do
          nil -> {:error, :not_found}
          recipe -> {:ok, serialize_recipe_full(recipe)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_recipe(map(), map()) :: {:ok, map()} | {:error, term()}
  def create_recipe(user, attrs) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        attrs = Map.put(attrs, :account_id, identity.account_id)
        {:ok, recipe} = RecipeRepo.create_recipe(attrs)
        {:ok, serialize_recipe(recipe)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec search_recipes(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def search_recipes(user, query) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        recipes = RecipeRepo.search_recipes_by_title(identity.account_id, query)
        {:ok, Enum.map(recipes, &serialize_recipe/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------------
  # Favorites
  # -------------------------------------------------------------------------

  @spec add_favorite(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def add_favorite(user, recipe_id) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        case RecipeRepo.add_favorite(identity.account_id, recipe_id) do
          {:ok, _fav} -> {:ok, %{recipe_id: recipe_id, added: true}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec remove_favorite(map(), pos_integer()) :: :ok | {:error, term()}
  def remove_favorite(user, recipe_id) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        RecipeRepo.remove_favorite(identity.account_id, recipe_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_favorites(map()) :: {:ok, [map()]} | {:error, term()}
  def list_favorites(user) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        recipes = RecipeRepo.list_favorites(identity.account_id)
        {:ok, Enum.map(recipes, &serialize_recipe/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec is_favorite?(map(), pos_integer()) :: boolean()
  def is_favorite?(user, recipe_id) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} -> RecipeRepo.is_favorite?(identity.account_id, recipe_id)
      {:error, _} -> false
    end
  end

  # -------------------------------------------------------------------------
  # Ingredients
  # -------------------------------------------------------------------------

  @spec list_ingredients() :: {:ok, [map()]}
  def list_ingredients do
    ingredients = RecipeRepo.list_ingredients()
    {:ok, Enum.map(ingredients, &serialize_ingredient/1)}
  end

  @spec find_ingredients_by_names([String.t()]) :: {:ok, [map()]}
  def find_ingredients_by_names(names) do
    ingredients = RecipeRepo.find_ingredients_by_names(names)
    {:ok, Enum.map(ingredients, &serialize_ingredient/1)}
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp serialize_recipe(r) do
    %{
      id: r.id,
      name: r.name,
      title: r.title,
      description: r.description,
      prep_time_minutes: r.prep_time_minutes,
      cook_time_minutes: r.cook_time_minutes,
      calories_per_serving: r.calories_per_serving,
      suitable_for_slots: Enum.map(r.suitable_for_slots || [], &Atom.to_string/1)
    }
  end

  defp serialize_recipe_full(r) do
    base = serialize_recipe(r)

    Map.merge(base, %{
      recipe_steps:
        Enum.map(r.recipe_steps || [], fn s ->
          %{id: s.id, step_number: s.step_number, instruction: s.instruction}
        end),
      recipe_ingredients:
        Enum.map(r.recipe_ingredients || [], fn ri ->
          %{
            id: ri.id,
            quantity_milli: ri.quantity_milli,
            unit: Atom.to_string(ri.unit),
            ingredient: ri.ingredient && %{id: ri.ingredient.id, name: ri.ingredient.name}
          }
        end)
    })
  end

  defp serialize_ingredient(i) do
    %{
      id: i.id,
      name: i.name,
      category: Atom.to_string(i.category),
      calories_per_100: i.calories_per_100,
      protein_g_per_100: i.protein_g_per_100,
      carbs_g_per_100: i.carbs_g_per_100,
      fat_g_per_100: i.fat_g_per_100
    }
  end
end
