defmodule MealPlannerApi.Services.ShoppingRebuilder do
  @moduledoc """
  Pure stateless functions for computing net shopping shortages
  from confirmed scheduled meals and available inventory.

  No side effects. All DB writes are done by the caller
  (Generation.Server). This separation makes the math testable
  without database fixtures.

  ## Usage

      meals = [%{id: "m1", recipe_id: "r1", date: ~D[2026-09-25],
                 recipe: %{recipe_ingredients: [%{ingredient_id: "flour", unit: :g, quantity_milli: 200_000}]}}]
      pool = %{{"flour", :g} => 100_000}
      ShoppingRebuilder.compute_net_shortages(meals, pool)
      # => [%{scheduled_meal_id: "m1", planned_date: ~D[2026-09-25],
      #       ingredient_id: "flour", unit: :g, quantity_milli: 100_000}]
  """

  @doc """
  Computes net shopping shortages for a list of confirmed meals.

  For each meal's recipe ingredients, subtracts greedily from the
  available inventory pool. Returns per-meal rows only where
  shortage > 0. The pool is mutable across meals (greedy depletion):
  once an ingredient is consumed by an earlier meal, later meals
  see the reduced pool.

  ## Parameters

    * `meals` — list of scheduled meals with preloaded recipe and
      recipe_ingredients. Each meal has `%{id, recipe_id, date, recipe}`.
      Meals with `recipe_id == nil` are skipped.
    * `pool` — `%{{ingredient_id, unit} => available_quantity_milli}`,
      typically built from `Inventory.available_for/2`.

  ## Returns

  A flat list of `%{scheduled_meal_id, planned_date, ingredient_id,
  unit, quantity_milli}` maps, one per ingredient-unit with a positive
  shortage. No rounding, no Float, no package math.
  """
  @spec compute_net_shortages([map()], %{{term(), atom()} => non_neg_integer()}) :: [map()]
  def compute_net_shortages(meals, pool) when is_list(meals) and is_map(pool) do
    {rows, _remaining_pool} =
      Enum.reduce(meals, {[], pool}, fn meal, {acc, current_pool} ->
        case meal.recipe_id do
          nil ->
            {acc, current_pool}

          _recipe_id ->
            ingredients = get_recipe_ingredients(meal)
            process_meal_ingredients(meal, ingredients, acc, current_pool)
        end
      end)

    Enum.reverse(rows)
  end

  defp get_recipe_ingredients(%{recipe: %{recipe_ingredients: ingredients}})
       when is_list(ingredients),
       do: ingredients

  defp get_recipe_ingredients(_), do: []

  defp process_meal_ingredients(meal, ingredients, acc, pool) do
    Enum.reduce(ingredients, {acc, pool}, fn ri, {rows, current_pool} ->
      key = {ri.ingredient_id, ri.unit}
      available = Map.get(current_pool, key, 0)
      needed = ri.quantity_milli

      cond do
        available >= needed ->
          # Fully covered — deduct from pool, no shortage row
          {rows, Map.put(current_pool, key, available - needed)}

        available > 0 ->
          # Partially covered — deduct what's available, emit shortage
          shortage = needed - available

          row = %{
            scheduled_meal_id: meal.id,
            planned_date: meal.date,
            ingredient_id: ri.ingredient_id,
            unit: ri.unit,
            quantity_milli: shortage
          }

          {[row | rows], Map.put(current_pool, key, 0)}

        true ->
          # Nothing available — full shortage
          row = %{
            scheduled_meal_id: meal.id,
            planned_date: meal.date,
            ingredient_id: ri.ingredient_id,
            unit: ri.unit,
            quantity_milli: needed
          }

          {[row | rows], current_pool}
      end
    end)
  end
end
