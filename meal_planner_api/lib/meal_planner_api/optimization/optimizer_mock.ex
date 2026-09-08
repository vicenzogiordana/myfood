defmodule MealPlannerApi.Optimization.OptimizerMock do
  @moduledoc """
  Test double for `OptimizerPort`.

  Returns deterministic results. Configurable to produce errors on demand
  via application env:
  - `:optimizer_mock_error` — causes `select_weekly_menu` to return error
  """

  @behaviour MealPlannerApi.Optimization.OptimizerPort

  @impl true
  def select_weekly_menu(payload) do
    if Application.get_env(:meal_planner_api, :optimizer_mock_error, false) do
      {:error, :optimizer_unavailable}
    else
      days = Map.get(payload, "days", Map.get(payload, :days, []))

      candidates_by_slot =
        Map.get(payload, "candidates_by_slot", Map.get(payload, :candidates_by_slot, %{}))

      slots =
        Map.get(payload, "slots", Map.get(payload, :slots, Map.keys(candidates_by_slot)))

      meals = build_mock_meals(days, candidates_by_slot, slots)
      {:ok, %{"meals" => meals}}
    end
  end

  @impl true
  def health_check, do: :ok

  # ---

  defp build_mock_meals(days, candidates_by_slot, slots) do
    Enum.flat_map(days, fn day ->
      Enum.map(slots, fn slot ->
        slot_str = to_string(slot)

        first =
          candidates_by_slot |> candidates_for_slot(slot_str) |> List.first() |> stringify_keys()

        Map.merge(first || %{}, %{
          "day" => day,
          "slot" => slot_str,
          "recipe_id" => (first && first["recipe_id"]) || "mock-recipe-#{slot_str}"
        })
        |> Map.put_new(
          "estimated_cost_cents",
          if first && is_map(first) do
            # Use price_per_serving_cents if available, else generate mock
            # based on slot (breakfast = 3200 to match test expectations)
            case first["price_per_serving_cents"] do
              nil ->
                case slot_str do
                  "breakfast" -> 3200
                  "lunch" -> 2200
                  "dinner" -> 2800
                  _ -> 0
                end

              0 ->
                case slot_str do
                  "breakfast" -> 3200
                  "lunch" -> 2200
                  "dinner" -> 2800
                  _ -> 0
                end

              val ->
                val
            end
          else
            case slot_str do
              "breakfast" -> 3200
              "lunch" -> 2200
              "dinner" -> 2800
              _ -> 0
            end
          end
        )
      end)
    end)
  end

  defp candidates_for_slot(candidates_by_slot, slot_name) do
    Map.get(candidates_by_slot, slot_name) ||
      Enum.find_value(candidates_by_slot, [], fn {slot, candidates} ->
        if to_string(slot) == slot_name, do: candidates
      end) || []
  end

  defp stringify_keys(nil), do: nil

  defp stringify_keys(candidate),
    do: Map.new(candidate, fn {key, value} -> {to_string(key), value} end)
end
