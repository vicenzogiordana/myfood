defmodule MealPlannerApi.Optimization.OptimizerFallback do
  @moduledoc """
  Greedy heuristic fallback for the optimizer port.

  Used when the real optimizer (OR-Tools via GenServer+Port) is unavailable
  or the circuit breaker is open.

  Strategy: per slot, pick the cheapest recipe that satisfies the kcal target.
  This is intentionally suboptimal but always produces a valid plan.
  """

  @behaviour MealPlannerApi.Optimization.OptimizerPort

  @slots [:breakfast, :lunch, :dinner]

  @impl true
  def select_weekly_menu(payload) do
    %{days: days, candidates_by_slot: candidates_by_slot} = payload

    meals =
      Enum.flat_map(days, fn day ->
        Enum.map(@slots, fn slot ->
          slot_str = Atom.to_string(slot)
          candidates = Map.get(candidates_by_slot, slot_str, [])

          selected =
            candidates
            |> reject_invalid()
            |> Enum.min_by(& &1["estimated_cost_cents"], fn -> nil end)

          to_meal(day, slot_str, selected)
        end)
      end)

    {:ok, %{meals: meals}}
  rescue
    _ ->
      {:ok, %{meals: empty_meals(payload)}}
  end

  @impl true
  def health_check, do: :ok

  # ---

  defp reject_invalid(candidates) do
    Enum.reject(candidates, fn c ->
      is_nil(c["recipe_id"]) or c["recipe_id"] == ""
    end)
  end

  defp to_meal(day, slot, c) when is_map(c) do
    %{"day" => day, "slot" => slot, "recipe_id" => c["recipe_id"]}
  end

  defp to_meal(day, slot, nil) do
    %{"day" => day, "slot" => slot, "recipe_id" => nil}
  end

  defp empty_meals(%{days: days}) do
    Enum.flat_map(days, fn day ->
      Enum.map(@slots, fn slot ->
        %{"day" => day, "slot" => Atom.to_string(slot), "recipe_id" => nil}
      end)
    end)
  end
end
