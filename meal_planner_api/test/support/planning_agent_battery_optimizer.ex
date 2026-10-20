defmodule MealPlannerApi.PlanningAgent.BatteryOptimizer do
  @moduledoc """
  Hand-written optimizer fake for the offline battery tests (issue #109):
  a greedy plan that honours the payload's variety rules, so a well-behaved
  scripted agent gets valid Proposals without the Python solver.

  It keeps every fixed meal, then fills each free day and slot with the
  first candidate that is not on the previous or next day in the same slot
  and stays within the variety cap over any 7 days, counting the prior
  meals. It never takes an avoided recipe for its day and slot (a Released
  Meal must change, issue #148). A candidate not yet planned anywhere is
  preferred.
  """

  @behaviour MealPlannerApi.PlanningAgent.Optimizer

  @impl true
  def solve(payload, _opts) do
    cap = get_in(payload, ["constraints", "variety_cap"]) || 2
    prior = Enum.map(payload["prior_meals"] || [], &meal/1)
    fixed = Enum.map(payload["fixed_meals"] || [], &meal/1)
    fixed_keys = MapSet.new(fixed, &{&1.date, &1.slot})
    avoided = MapSet.new(payload["avoided_meals"] || [], &meal/1)

    free =
      for day <- payload["days"],
          slot <- payload["slots"],
          not MapSet.member?(fixed_keys, {Date.from_iso8601!(day), slot}),
          do: {Date.from_iso8601!(day), slot}

    planned =
      Enum.reduce(free, fixed, fn {date, slot}, planned ->
        ids =
          for candidate <- payload["candidates_by_slot"][slot],
              id = candidate["recipe_id"],
              not MapSet.member?(avoided, %{date: date, slot: slot, recipe_id: id}),
              do: id

        placed = prior ++ planned
        allowed = Enum.filter(ids, &allowed?(&1, date, slot, placed, cap))
        unused = Enum.reject(allowed, fn id -> Enum.any?(placed, &(&1.recipe_id == id)) end)
        recipe_id = List.first(unused) || List.first(allowed) || hd(ids)
        planned ++ [%{date: date, slot: slot, recipe_id: recipe_id}]
      end)

    meals =
      planned
      |> Enum.sort_by(&{Date.to_iso8601(&1.date), &1.slot})
      |> Enum.map(
        &%{"day" => Date.to_iso8601(&1.date), "slot" => &1.slot, "recipe_id" => &1.recipe_id}
      )

    {:ok, %{"meals" => meals}}
  end

  defp meal(%{"day" => day, "slot" => slot, "recipe_id" => id}),
    do: %{date: Date.from_iso8601!(day), slot: slot, recipe_id: id}

  defp allowed?(id, date, slot, placed, cap) do
    same = Enum.filter(placed, &(&1.recipe_id == id))
    adjacent? = Enum.any?(same, &(&1.slot == slot and abs(Date.diff(&1.date, date)) == 1))

    within_cap? =
      Enum.all?(-6..0, fn offset ->
        start = Date.add(date, offset)
        Enum.count(same, &(Date.diff(&1.date, start) in 0..6)) + 1 <= cap
      end)

    not adjacent? and within_cap?
  end
end
