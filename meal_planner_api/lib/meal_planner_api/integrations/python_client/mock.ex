defmodule MealPlannerApi.Integrations.PythonClient.Mock do
  @moduledoc """
  Deterministic mock for the Python OR-Tools optimizer.

  Simulates slot-by-slot progress with artificial delays, then returns a
  complete proposal. Used in dev + test environments.

  Since this is a Phoenix Channel environment, progress is simulated
  via `Process.send_after` — not real broadcasts. The GenerationServer
  test harness intercepts these by stubbing `send(self(), {:broadcast, ...})`.
  """

  @doc "Returns mock optimization result."
  @spec optimize_menu([map()], map(), map()) :: {:ok, [map()]}
  def optimize_menu(slots, _recipe_prices, _recipe_macros) do
    optimized =
      Enum.map(slots, fn slot ->
        %{
          date: slot["date"] || slot[:date] || "2026-06-03",
          slot: slot["slot"] || slot[:slot] || "lunch",
          recipe_id: "mock-recipe-#{:rand.uniform(999)}",
          recipe_name: mock_recipe_name(),
          price_cents: :rand.uniform(2000) + 500,
          macros: %{
            protein_g: :rand.uniform(40),
            calories: :rand.uniform(600),
            carbs_g: :rand.uniform(60)
          }
        }
      end)

    {:ok, optimized}
  end

  @spec optimize_slot(map(), map(), map()) :: {:ok, map()}
  def optimize_slot(slot, recipe_prices, recipe_macros) do
    case optimize_menu([slot], recipe_prices, recipe_macros) do
      {:ok, [result | _]} -> {:ok, result}
      other -> other
    end
  end

  @spec extract_shopping_list([String.t()], map(), map()) :: {:ok, [map()]}
  def extract_shopping_list(recipe_ids, _recipe_prices, _recipe_macros) do
    items =
      Enum.map(recipe_ids, fn recipe_id ->
        %{
          recipe_id: recipe_id,
          ingredient_name: "Mock Ingredient for #{recipe_id}",
          quantity: :rand.uniform(3) + 1,
          unit: "kg",
          estimated_price_cents: :rand.uniform(1500) + 200
        }
      end)

    {:ok, items}
  end

  def base_url, do: "http://mock-optimizer:8000"

  defp mock_recipe_name do
    names = [
      "Pollo al horno con hierbas",
      "Ensalada César",
      "Pasta con tomate",
      "Arroz con verduras",
      "Carne mechada",
      "Tarta de espinaca",
      "Sopa de pollo",
      "Fish and chips"
    ]

    Enum.random(names)
  end
end
