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
      %{"days" => days, "candidates_by_slot" => candidates_by_slot} = payload
      meals = build_mock_meals(days, candidates_by_slot)
      {:ok, %{meals: meals}}
    end
  end

  @impl true
  def health_check, do: :ok

  # ---

  defp build_mock_meals(days, candidates_by_slot) do
    slots = [:breakfast, :lunch, :dinner]

    Enum.flat_map(days, fn day ->
      Enum.map(slots, fn slot ->
        slot_str = Atom.to_string(slot)
        candidates = Map.get(candidates_by_slot, slot_str, [])
        first = List.first(candidates)

        %{
          "day" => day,
          "slot" => slot_str,
          "recipe_id" => (first && first["recipe_id"]) || "mock-recipe-#{slot_str}",
          # Pass through price from candidate if available (historical price lookup)
          "estimated_cost_cents" =>
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
        }
      end)
    end)
  end
end
