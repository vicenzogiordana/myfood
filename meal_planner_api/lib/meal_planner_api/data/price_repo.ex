defmodule MealPlannerApi.Data.PriceRepo do
  @moduledoc """
  Pure data access for ingredient_prices and recipe_prices.

  No business logic. Just queries and persistence for the price-sync pipeline.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Shopping.{IngredientPrice, RecipePrice}

  # -------------------------------------------------------------------------
  # Ingredient prices
  # -------------------------------------------------------------------------

  @spec latest_prices([pos_integer()]) :: %{pos_integer() => pos_integer()}
  def latest_prices(ingredient_ids) when is_list(ingredient_ids) do
    from(ip in IngredientPrice,
      where: ip.ingredient_id in ^ingredient_ids,
      where: ip.scraped_at > ago(1, "day"),
      group_by: ip.ingredient_id,
      select: {ip.ingredient_id, min(ip.price_per_unit_cents)}
    )
    |> Repo.all()
    |> Enum.into(%{})
  end

  @spec latest_prices_map([pos_integer()]) :: %{
          pos_integer() => %{String.t() => pos_integer()}
        }
  def latest_prices_map(ingredient_ids) when is_list(ingredient_ids) do
    rows =
      from(ip in IngredientPrice,
        where: ip.ingredient_id in ^ingredient_ids,
        where: ip.scraped_at > ago(1, "day"),
        select: {ip.ingredient_id, ip.supermarket_id, ip.price_per_unit_cents}
      )
      |> Repo.all()

    rows
    |> Enum.group_by(fn {ing_id, _, _} -> ing_id end)
    |> Enum.map(fn {ing_id, entries} ->
      {ing_id, Enum.into(entries, %{}, fn {_, sup_id, price} -> {sup_id, price} end)}
    end)
    |> Enum.into(%{})
  end

  @spec best_price_per_ingredient([pos_integer()]) :: %{pos_integer() => pos_integer()}
  def best_price_per_ingredient(ingredient_ids) when is_list(ingredient_ids) do
    latest_prices(ingredient_ids)
  end

  @spec upsert_prices([map()]) :: {non_neg_integer(), [IngredientPrice.t()]}
  def upsert_prices(rows) when is_list(rows) do
    results =
      Enum.map(rows, fn attrs ->
        %IngredientPrice{}
        |> IngredientPrice.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:price_per_unit_cents, :unit, :scraped_at]},
          conflict_target: [:ingredient_id, :supermarket_id]
        )
      end)

    successes = Enum.count(results, &match?({:ok, _}, &1))
    inserted = Enum.map(results, fn {:ok, record} -> record end)
    {successes, inserted}
  end

  @spec get_recipe_price(pos_integer()) :: RecipePrice.t() | nil
  def get_recipe_price(recipe_id) do
    Repo.get_by(RecipePrice, recipe_id: recipe_id)
  end

  @spec get_recipe_prices([pos_integer()]) :: [RecipePrice.t()]
  def get_recipe_prices(recipe_ids) when is_list(recipe_ids) do
    from(rp in RecipePrice, where: rp.recipe_id in ^recipe_ids)
    |> Repo.all()
  end

  @spec compute_all_recipe_prices :: {non_neg_integer(), non_neg_integer()}
  @doc """
  Recomputes `price_per_serving_cents` for every recipe that has ingredients.

  Returns `{recipes_computed, recipes_skipped}`.
  A recipe is skipped if at least one ingredient lacks a price in `ingredient_prices`.
  """
  def compute_all_recipe_prices do
    recipes = load_all_recipes_with_ingredients()

    results =
      Enum.map(recipes, fn recipe ->
        compute_single_recipe_price(recipe)
      end)

    computed = Enum.count(results, &match?({:ok, _}, &1))
    skipped = Enum.count(results, &match?({:error, _}, &1))
    {computed, skipped}
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp load_all_recipes_with_ingredients do
    from(r in MealPlannerApi.Persistence.Catalog.Recipe,
      left_join: ri in assoc(r, :recipe_ingredients),
      left_join: i in assoc(ri, :ingredient),
      where: not is_nil(r.id),
      preload: [recipe_ingredients: {ri, ingredient: i}]
    )
    |> Repo.all()
  end

  defp compute_single_recipe_price(recipe) do
    ingredient_entries = recipe.recipe_ingredients

    prices =
      Enum.map(ingredient_entries, fn ri ->
        case ri.ingredient do
          %{id: ingredient_id, quantity: quantity, unit: unit} when not is_nil(ingredient_id) ->
            price =
              get_ingredient_price_for_quantity(ingredient_id, quantity, unit)
              |> case do
                nil -> :missing
                p -> p
              end

            {ri.id, price}

          _ ->
            {ri.id, :missing}
        end
      end)

    if Enum.any?(prices, fn {_, p} -> p == :missing end) do
      {:error, :missing_ingredient_price}
    else
      total_cents = prices |> Enum.map(fn {_, p} -> p end) |> Enum.sum()

      now = DateTime.utc_now()

      %RecipePrice{
        recipe_id: recipe.id,
        price_per_serving_cents: total_cents,
        last_calculated_at: now
      }
      |> RecipePrice.changeset(%{
        recipe_id: recipe.id,
        price_per_serving_cents: total_cents,
        last_calculated_at: now
      })
      |> Repo.insert(
        on_conflict: {:replace, [:price_per_serving_cents, :last_calculated_at]},
        conflict_target: :recipe_id
      )
    end
  end

  defp get_ingredient_price_for_quantity(ingredient_id, quantity, _unit) do
    case latest_prices([ingredient_id]) do
      %{^ingredient_id => cents} -> floor(cents * quantity)
      %{} -> nil
    end
  end
end
