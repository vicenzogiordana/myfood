defmodule MealPlannerApi.Services.PriceService do
  @moduledoc """
  Business logic layer for price data.

  Bridges the data layer (PriceRepo, UnitConversionRepo) with the generation
  pipeline. Handles the transformation from raw DB prices → optimizer input.
  """

  alias MealPlannerApi.Data.{PriceRepo, UserPreferenceRepo}
  alias MealPlannerApi.Persistence.Catalog

  # -------------------------------------------------------------------------
  # Price lookups
  # -------------------------------------------------------------------------

  @doc """
  Returns a map of `recipe_id => price_per_serving_cents` for the given recipes.

  Skips recipes with no price. Used to build `recipe_prices` input for OR-Tools.
  """
  @spec fetch_recipe_prices([pos_integer()]) :: %{pos_integer() => non_neg_integer()}
  def fetch_recipe_prices(recipe_ids) when is_list(recipe_ids) do
    recipe_ids
    |> PriceRepo.get_recipe_prices()
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{}, fn rp ->
      {rp.recipe_id, rp.price_per_serving_cents}
    end)
  end

  @doc """
  Returns recipe prices as floats (in currency units, not cents) for the Python API.

  Python OR-Tools expects prices in the same unit as budget_cents / 100.
  """
  @spec fetch_recipe_prices_float([pos_integer()]) :: %{pos_integer() => float()}
  def fetch_recipe_prices_float(recipe_ids) when is_list(recipe_ids) do
    recipe_ids
    |> PriceRepo.get_recipe_prices()
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{}, fn rp ->
      {rp.recipe_id, rp.price_per_serving_cents / 100.0}
    end)
  end

  # -------------------------------------------------------------------------
  # Slot list for optimization
  # -------------------------------------------------------------------------

  @doc """
  Builds the list of slots to optimize for a date range.

  Returns a list of slot maps with `available_recipe_ids` filtered by:
  - Excluded ingredients (from user preferences)
  - Excluded recipes (user override)
  - Recipe suitability (breakfast/lunch/dinner/snack)
  """
  @spec build_slot_list(map()) :: {:ok, [map()]} | {:error, :no_slots}
  def build_slot_list(%{
        account_id: _account_id,
        user_id: user_id,
        date_from: date_from,
        date_to: date_to,
        slot_types: slot_types,
        constraints: constraints
      }) do
    # Load user preferences (exclusions, protein target)
    user_prefs =
      case UserPreferenceRepo.get(user_id) do
        nil ->
          %{protein_g_per_meal: 25, default_exclusions: []}

        prefs ->
          %{
            protein_g_per_meal: prefs.protein_g_per_meal,
            default_exclusions: prefs.default_exclusions
          }
      end

    # Merge profile defaults with payload overrides
    resolved = merge_constraints(user_prefs, constraints)

    # Load all recipes with their prices
    all_recipes =
      Catalog.list_recipes_with_prices_and_ingredients()
      |> Enum.reject(fn recipe ->
        is_nil(Map.get(recipe, :recipe_price)) or
          Map.get(recipe.recipe_price, :price_per_serving_cents, 0) == 0
      end)

    # Filter by exclusions
    filtered =
      all_recipes
      |> filter_by_excluded_recipes(resolved.excluded_recipe_ids)
      |> filter_by_excluded_ingredients(resolved.excluded_ingredients)

    # Build slot list
    slots = generate_slots(date_from, date_to, slot_types, filtered, resolved)

    if slots == [], do: {:error, :no_slots}, else: {:ok, slots}
  rescue
    _ -> {:error, :no_slots}
  end

  # -------------------------------------------------------------------------
  # Constraints helpers
  # -------------------------------------------------------------------------

  @doc """
  Merges user profile defaults with constraint overrides from the request payload.

  Payload constraints take precedence over profile defaults.
  """
  @spec merge_constraints(map(), map() | nil) :: map()
  def merge_constraints(profile, nil), do: profile

  def merge_constraints(profile, overrides) when is_map(overrides) do
    %{
      protein_g_per_meal: overrides[:protein_g] || profile.protein_g_per_meal,
      max_budget_per_meal_cents: overrides[:budget_cents] || 10_000,
      max_calories: overrides[:max_calories] || 1000,
      excluded_recipe_ids: overrides[:excluded_recipe_ids] || [],
      excluded_ingredients:
        (overrides[:excluded_ingredients] || []) ++
          (profile.default_exclusions || [])
    }
  end

  @doc """
  Returns the list of valid recipe IDs for a given slot type.

  Excludes recipes that don't match the slot type (e.g. breakfast-only vs dinner).
  """
  @spec available_recipe_ids_for_slot([map()], String.t()) :: [pos_integer()]
  def available_recipe_ids_for_slot(recipes, slot_type) do
    recipes
    |> Enum.filter(&suitable_for_slot?(&1, slot_type))
    |> Enum.map(& &1.id)
  end

  # -------------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------------

  defp generate_slots(date_from, date_to, slot_types, recipes, constraints) do
    date_from = Date.from_iso8601!(date_from)
    date_to = Date.from_iso8601!(date_to)

    slot_types
    |> Enum.flat_map(fn slot_name ->
      Enum.map(Date.range(date_from, date_to), fn date ->
        %{
          date: Date.to_iso8601(date),
          slot: slot_name,
          available_recipe_ids: available_recipe_ids_for_slot(recipes, slot_name),
          constraints: %{
            budget_cents: constraints.max_budget_per_meal_cents,
            protein_g: constraints.protein_g_per_meal,
            max_calories: constraints.max_calories,
            excluded_recipe_ids: constraints.excluded_recipe_ids,
            excluded_ingredients: constraints.excluded_ingredients
          }
        }
      end)
    end)
  end

  defp filter_by_excluded_recipes(recipes, excluded_ids) when is_list(excluded_ids) do
    Enum.reject(recipes, fn r -> r.id in excluded_ids end)
  end

  defp filter_by_excluded_ingredients(recipes, exclusions) when is_list(exclusions) do
    Enum.reject(recipes, fn recipe ->
      has_excluded_ingredient?(recipe, exclusions)
    end)
  end

  defp has_excluded_ingredient?(recipe, exclusions) do
    recipe_ingredients = Map.get(recipe, :recipe_ingredients, [])

    Enum.any?(recipe_ingredients, fn ri ->
      ingredient = Map.get(ri, :ingredient)

      Enum.any?(exclusions, fn excluded ->
        ingredient &&
          String.downcase(ingredient.name) |> String.contains?(String.downcase(excluded))
      end)
    end)
  end

  defp suitable_for_slot?(recipe, slot) do
    suitable_slots = Map.get(recipe, :suitable_for_slots, []) |> Enum.map(&to_string/1)
    suitable_slots == [] || slot in suitable_slots
  end
end
