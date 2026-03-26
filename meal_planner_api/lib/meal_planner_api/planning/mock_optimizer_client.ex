defmodule MealPlannerApi.Planning.MockOptimizerClient do
  @moduledoc """
  Deterministic optimizer used in tests and fallback environments.
  """

  @behaviour MealPlannerApi.Planning.OptimizerClient

  @impl true
  def select_weekly_menu(payload) when is_map(payload) do
    constraints = Map.get(payload, "constraints", %{})

    with true <- valid_constraints?(constraints) do
      days = Map.get(payload, "days", [])
      slots = Map.get(payload, "slots", [])
      candidates_by_slot = Map.get(payload, "candidates_by_slot", %{})

      meals =
        days
        |> Enum.with_index()
        |> Enum.flat_map(fn {day, day_index} ->
          Enum.map(slots, fn slot ->
            candidate =
              candidates_by_slot
              |> Map.get(slot, [])
              |> pick_candidate(day_index)

            %{
              "day" => day,
              "slot" => slot,
              "recipe_id" => Map.get(candidate, "recipe_id")
            }
          end)
        end)

      {:ok, %{"meals" => meals}}
    else
      _ -> {:error, :invalid_constraints}
    end
  end

  defp valid_constraints?(constraints) when is_map(constraints) do
    macro_bounds = Map.get(constraints, "macro_bounds", %{})

    Enum.all?(["protein_g", "carbs_g", "fat_g"], fn key ->
      case Map.get(macro_bounds, key) do
        %{"min" => min, "max" => max} when is_number(min) and is_number(max) -> min <= max
        _ -> false
      end
    end)
  end

  defp valid_constraints?(_), do: false

  defp pick_candidate([], _day_index), do: %{}

  defp pick_candidate(candidates, day_index) do
    index = rem(day_index, length(candidates))
    Enum.at(candidates, index, %{})
  end
end
