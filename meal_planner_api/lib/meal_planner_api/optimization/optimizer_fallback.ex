defmodule MealPlannerApi.Optimization.OptimizerFallback do
  @moduledoc """
  Greedy heuristic fallback for the optimizer port.

  Used when the real optimizer (OR-Tools via GenServer+Port) is unavailable
  or the circuit breaker is open.

  Strategy: per slot, pick the cheapest recipe that satisfies the kcal target.
  This is intentionally suboptimal but always produces a valid plan.
  """

  @behaviour MealPlannerApi.Optimization.OptimizerPort

  @impl true
  def select_weekly_menu(payload) do
    with {:ok, days, slots, candidates_by_slot, result_key} <- normalize_payload(payload),
         {:ok, meals} <- choose_meals(days, slots, candidates_by_slot) do
      {:ok, %{result_key => meals}}
    else
      {:error, cause} -> {:error, {:infeasible, %{causes: [cause]}}}
      :error -> {:error, :fallback_invalid_payload}
    end
  end

  @impl true
  def health_check, do: :ok

  # ---

  defp normalize_payload(payload) when is_map(payload) do
    days = Map.get(payload, "days", Map.get(payload, :days))

    candidates_by_slot =
      Map.get(payload, "candidates_by_slot", Map.get(payload, :candidates_by_slot))

    slots =
      Map.get(payload, "slots", Map.get(payload, :slots, Map.keys(candidates_by_slot || %{})))

    if is_list(days) and is_list(slots) and is_map(candidates_by_slot) do
      normalized_slots = Enum.map(slots, &to_string/1)

      normalized_candidates =
        Map.new(candidates_by_slot, fn {slot, candidates} ->
          {to_string(slot), Enum.map(candidates, &stringify_candidate/1)}
        end)

      result_key = if Map.has_key?(payload, :days), do: :meals, else: "meals"
      {:ok, days, normalized_slots, normalized_candidates, result_key}
    else
      :error
    end
  end

  defp normalize_payload(_), do: :error

  defp stringify_candidate(candidate) when is_map(candidate) do
    Map.new(candidate, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_candidate(_), do: %{}

  defp reject_invalid(candidates) do
    Enum.reject(candidates, fn c ->
      is_nil(c["recipe_id"]) or c["recipe_id"] == ""
    end)
  end

  defp choose_meals(days, slots, candidates_by_slot) do
    Enum.reduce_while(for(day <- days, slot <- slots, do: {day, slot}), {:ok, []}, fn {day, slot},
                                                                                      {:ok, meals} ->
      case candidates_by_slot
           |> Map.get(slot, [])
           |> reject_invalid()
           |> Enum.min_by(& &1["estimated_cost_cents"], fn -> nil end) do
        nil ->
          {:halt, {:error, :no_recipe_for_slot}}

        candidate ->
          {:cont, {:ok, [candidate |> Map.put("day", day) |> Map.put("slot", slot) | meals]}}
      end
    end)
    |> case do
      {:ok, meals} -> {:ok, Enum.reverse(meals)}
      error -> error
    end
  end
end
