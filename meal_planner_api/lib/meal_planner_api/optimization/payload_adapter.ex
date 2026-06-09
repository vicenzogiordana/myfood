defmodule MealPlannerApi.Optimization.PayloadAdapter do
  @moduledoc """
  Translates between GenerationServer's slot-based format and OptimizerServer's
  Python-compatible format.

  GenerationServer builds:
  - slots: [%{date, slot, available_recipe_ids, constraints}]
  - recipe_prices: %{"id" => float}
  - recipe_macros: %{"id" => %{protein_g, calories, carbs_g}}

  OptimizerServer (optimizador.py) expects:
  - days: [date_string]
  - slots: [slot_type_string]
  - constraints: %{weekly_budget_cents, macro_bounds: %{protein_g: %{min, max}, ...}}
  - candidates_by_slot: %{slot_type => [%{recipe_id, estimated_cost_cents, protein_g_per_serving, ...}]}
  """

  @doc """
  Translates Generation pipeline format to OptimizerServer format.

  ## Examples

      iex> slots = [%{date: "2026-06-03", slot: :lunch, available_recipe_ids: ["1"], constraints: %{budget_cents: 5000}}]
      iex> recipe_prices = %{"1" => 12.50}
      iex> recipe_macros = %{"1" => %{protein_g: 25, calories: 450, carbs_g: 30}}
      iex> PayloadAdapter.build_optimizer_payload(slots, recipe_prices, recipe_macros)
      %{
        days: ["2026-06-03"],
        slots: ["lunch"],
        constraints: %{weekly_budget_cents: 5000, macro_bounds: %{...}},
        candidates_by_slot: %{"lunch" => [%{recipe_id: "1", estimated_cost_cents: 1250, ...}]}
      }
  """
  @spec build_optimizer_payload(
          slots :: [
            %{
              date: String.t(),
              slot: atom(),
              available_recipe_ids: [String.t()],
              constraints: map()
            }
          ],
          recipe_prices :: %{String.t() => float()},
          recipe_macros :: %{
            String.t() => %{protein_g: integer(), calories: integer(), carbs_g: integer()}
          }
        ) :: map()
  def build_optimizer_payload(slots, recipe_prices, recipe_macros)
      when is_list(slots) and is_map(recipe_prices) and is_map(recipe_macros) do
    # Extract unique days and slot types
    days = slots |> Enum.map(& &1.date) |> Enum.uniq()
    slot_types = slots |> Enum.map(&(&1.slot |> to_string())) |> Enum.uniq()

    # Build constraints (weekly aggregate)
    weekly_budget = compute_weekly_budget(slots)
    macro_bounds = compute_macro_bounds(slots)

    # Build candidates_by_slot
    candidates_by_slot = build_candidates_by_slot(slots, recipe_prices, recipe_macros)

    %{
      days: days,
      slots: slot_types,
      constraints: %{
        weekly_budget_cents: weekly_budget,
        macro_bounds: macro_bounds
      },
      candidates_by_slot: candidates_by_slot
    }
  end

  @doc """
  Translates OptimizerServer response to GenerationServer format with enriched recipe data.

  ## Examples

      iex> optimizer_result = {:ok, %{meals: [%{day: "2026-06-03", slot: "lunch", recipe_id: "1"}]}}
      iex> recipe_data = %{"1" => %{name: "Pollo", price_cents: 1250, protein_g: 25, calories: 450, carbs_g: 30}}
      iex> PayloadAdapter.translate_response(optimizer_result, recipe_data)
      [%{date: "2026-06-03", slot: "lunch", recipe_id: "1", recipe_name: "Pollo", price_cents: 1250, macros: %{...}}]
  """
  @spec translate_response(
          optimizer_result ::
            {:ok, %{meals: [%{day: String.t(), slot: String.t(), recipe_id: String.t()}]}}
            | {:error, term()},
          recipe_data :: %{
            String.t() => %{
              name: String.t(),
              price_cents: integer(),
              protein_g: integer(),
              calories: integer(),
              carbs_g: integer()
            }
          }
        ) ::
          {:ok,
           [
             %{
               date: String.t(),
               slot: String.t(),
               recipe_id: String.t(),
               recipe_name: String.t(),
               price_cents: integer(),
               macros: map()
             }
           ]}
          | {:error, term()}
  def translate_response({:ok, %{meals: meals}}, recipe_data) do
    translated =
      Enum.map(meals, fn %{day: day, slot: slot, recipe_id: recipe_id} ->
        recipe = Map.get(recipe_data, recipe_id, %{})

        %{
          date: day,
          slot: slot,
          recipe_id: recipe_id,
          recipe_name: Map.get(recipe, :name, "Unknown Recipe"),
          price_cents: Map.get(recipe, :price_cents, 0),
          macros: %{
            protein_g: Map.get(recipe, :protein_g, 0),
            calories: Map.get(recipe, :calories, 0),
            carbs_g: Map.get(recipe, :carbs_g, 0)
          }
        }
      end)

    {:ok, translated}
  end

  def translate_response({:error, reason}, _recipe_data) do
    {:error, reason}
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp compute_weekly_budget(slots) do
    slots
    |> Enum.flat_map(fn slot ->
      case slot.constraints do
        %{budget_cents: budget} -> [budget]
        %{"budget_cents" => budget} -> [budget]
        _ -> []
      end
    end)
    |> case do
      # default: 500 USD/week
      [] -> 50_000
      budgets -> Enum.sum(budgets)
    end
  end

  defp compute_macro_bounds(slots) do
    # Sum per-slot constraints for weekly bounds
    totals =
      slots
      |> Enum.reduce({0, 0, 0}, fn slot, {p, c, f} ->
        constraints = slot.constraints || %{}
        protein = constraints[:protein_g] || constraints["protein_g"] || 25
        # default: 3x protein
        carbs = protein * 3
        # default: 40% of protein
        fat = protein * 0.4
        {p + protein, c + carbs, f + fat}
      end)

    {protein_sum, carbs_sum, fat_sum} = totals

    %{
      protein_g: %{min: protein_sum * 0.7, max: protein_sum * 1.3},
      carbs_g: %{min: carbs_sum * 0.7, max: carbs_sum * 1.3},
      fat_g: %{min: fat_sum * 0.7, max: fat_sum * 1.3}
    }
  end

  defp build_candidates_by_slot(slots, recipe_prices, recipe_macros) do
    slots
    |> Enum.group_by(fn slot -> to_string(slot.slot) end)
    |> Enum.into(%{}, fn {slot_type, slot_group} ->
      # Collect all recipe IDs from all slots of this type, deduplicate
      recipe_ids =
        slot_group
        |> Enum.flat_map(fn slot -> slot.available_recipe_ids || [] end)
        |> Enum.uniq()

      # Build candidate list with price and macros
      candidates =
        Enum.map(recipe_ids, fn recipe_id ->
          price = Map.get(recipe_prices, recipe_id, 0.0)
          macros = Map.get(recipe_macros, recipe_id, %{protein_g: 25, calories: 450, carbs_g: 30})

          %{
            recipe_id: recipe_id,
            estimated_cost_cents: round(price * 100),
            protein_g_per_serving: macros[:protein_g] || 25,
            carbs_g_per_serving: macro_estimate(macros, :carbs_g),
            fat_g_per_serving: macro_estimate(macros, :fat)
          }
        end)

      {slot_type, candidates}
    end)
  end

  defp macro_estimate(macros, :carbs_g) do
    # Use carbs_g if available, else estimate from calories: carbs = calories / 4
    case macros do
      %{carbs_g: v} -> v
      %{carbs: v} -> v
      %{calories: cal} -> cal / 4
      # default
      _ -> 75
    end
  end

  defp macro_estimate(macros, :fat) do
    # Use fat if available, else estimate: fat = protein * 0.4
    case macros do
      %{fat_g: v} -> v
      %{fat: v} -> v
      %{protein_g: p} -> p * 0.4
      # default
      _ -> 10
    end
  end
end
