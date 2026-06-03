defmodule MealPlannerApi.Integrations.PythonClient do
  @moduledoc """
  HTTP client for the Python OR-Tools optimization service.

  Used by GenerationServer during planning to call the optimizer.
  The Python service must be reachable at `python_optimizer_url` (default: http://localhost:8000).

  ## Python API protocol

  `POST /api/v1/optimize-menu`

  Request body:

      %{
        "slots": [
          %{
            "date": "2026-06-03",
            "slot": "lunch",
            "available_recipe_ids": ["id1", "id2", ...],
            "constraints": %{
              "budget_cents": 5000,
              "protein_g": 30,
              "max_calories": 800,
              "excluded_recipe_ids": [],
              "excluded_ingredients": ["maní"]
            }
          }
        ],
        "recipe_prices": %{"id1" => 1200, "id2": 950, ...},
        "recipe_macros": %{
          "id1" => %{protein_g: 25, calories: 450, carbs_g: 30}
        }
      }

  Response (200):

      %{
        "slots": [
          %{
            "date": "2026-06-03",
            "slot": "lunch",
            "recipe_id": "id2",
            "recipe_name": "Pollo al horno",
            "price_cents": 950,
            "macros": %{protein_g: 28, calories: 420, carbs_g: 25}
          }
        ]
      }

  OR-Tools handshake protocol (not exposed here, handled by optimizador.py):
  1. Client POSTs solve request
  2. Server responds with {"status": "solving", "slot_key": "..."}
  3. Server streams progress via "slot_progress" events
  4. Server sends final solution with "proposal_ready"

  For now we use a simple request/response model (no streaming from Elixir).
  """

  @base_url Application.compile_env(
              :meal_planner_api,
              :python_optimizer_url,
              "http://localhost:8000"
            )
  @timeout 60_000

  @typedoc "A single slot constraint set."
  @type constraints :: %{
          budget_cents: non_neg_integer(),
          protein_g: non_neg_integer(),
          max_calories: non_neg_integer(),
          excluded_recipe_ids: [String.t()],
          excluded_ingredients: [String.t()]
        }

  @typedoc "A slot to be optimized."
  @type slot :: %{
          date: String.t(),
          slot: String.t(),
          available_recipe_ids: [String.t()],
          constraints: constraints()
        }

  @typedoc "Single slot result from the optimizer."
  @type optimized_slot :: %{
          date: String.t(),
          slot: String.t(),
          recipe_id: String.t(),
          recipe_name: String.t(),
          price_cents: non_neg_integer(),
          macros: %{protein_g: integer(), calories: integer(), carbs_g: integer()}
        }

  # -------------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------------

  @doc """
  Runs full menu optimization across all slots.

  Returns `{:ok, [%optimized_slot{}]}` or `{:error, :timeout | :unreachable | :no_valid_plan}`.
  """
  @spec optimize_menu([slot()], map(), map()) ::
          {:ok, [optimized_slot()]}
          | {:error, :timeout | :unreachable | :no_valid_plan}
  def optimize_menu(slots, recipe_prices, recipe_macros)
      when is_list(slots) and is_map(recipe_prices) and is_map(recipe_macros) do
    body = %{
      slots: slots,
      recipe_prices: recipe_prices,
      recipe_macros: recipe_macros
    }

    case Tesla.post("#{@base_url}/api/v1/optimize-menu", body,
           receive_timeout: @timeout,
           json: false
         ) do
      {:ok, %{status: 200, body: %{"slots" => optimized_slots}}} ->
        {:ok, Enum.map(optimized_slots, &cast_optimized_slot/1)}

      {:ok, %{status: 200, body: %{"error" => reason}}} ->
        {:error, String.to_atom(reason)}

      {:ok, %{status: 200, body: %{"status" => "no_valid_plan"}}} ->
        {:error, :no_valid_plan}

      {:ok, %{status: status}} when status >= 400 ->
        {:error, :unreachable}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :unreachable}
    end
  end

  @doc """
  Re-optimizes a single slot (after user modification).

  Returns `{:ok, optimized_slot}` or `{:error, term()}`.
  """
  @spec optimize_slot(slot(), map(), map()) ::
          {:ok, optimized_slot()}
          | {:error, :timeout | :unreachable | :no_valid_plan}
  def optimize_slot(slot, recipe_prices, recipe_macros) do
    case optimize_menu([slot], recipe_prices, recipe_macros) do
      {:ok, [result | _]} -> {:ok, result}
      other -> other
    end
  end

  @doc """
  Extracts a shopping list from confirmed recipe IDs.

  Returns `{:ok, [shopping_item]}` or `{:error, term()}`.
  """
  @spec extract_shopping_list([String.t()], map(), map()) ::
          {:ok, [map()]}
          | {:error, :timeout | :unreachable}
  def extract_shopping_list(recipe_ids, recipe_prices, recipe_macros)
      when is_list(recipe_ids) and is_map(recipe_prices) and is_map(recipe_macros) do
    body = %{
      recipe_ids: recipe_ids,
      recipe_prices: recipe_prices,
      recipe_macros: recipe_macros
    }

    case Tesla.post("#{@base_url}/api/v1/shopping-list", body,
           receive_timeout: @timeout,
           json: false
         ) do
      {:ok, %{status: 200, body: %{"items" => items}}} ->
        {:ok, items}

      {:ok, %{status: status}} when status >= 400 ->
        {:error, :unreachable}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :unreachable}
    end
  end

  @doc "The configured Python optimizer base URL."
  @spec base_url() :: String.t()
  def base_url, do: @base_url

  # -------------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------------

  defp cast_optimized_slot(%{
         "date" => date,
         "slot" => slot,
         "recipe_id" => recipe_id,
         "recipe_name" => recipe_name,
         "price_cents" => price_cents,
         "macros" => macros
       }) do
    %{
      date: date,
      slot: slot,
      recipe_id: recipe_id,
      recipe_name: recipe_name,
      price_cents: price_cents,
      macros: %{
        protein_g: macros["protein_g"] || 0,
        calories: macros["calories"] || 0,
        carbs_g: macros["carbs_g"] || 0
      }
    }
  end

  defp cast_optimized_slot(_), do: nil
end
