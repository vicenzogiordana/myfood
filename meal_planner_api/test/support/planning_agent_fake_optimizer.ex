defmodule MealPlannerApi.PlanningAgent.FakeOptimizer do
  @moduledoc """
  Hand-written optimizer fake for planning agent tests.

  Options: `:notify` receives `{:optimizer_payload, payload}`; `:notify_opts`
  receives `{:optimizer_opts, opts}`, the options the call was made with; `:result` is a
  1-arity function from the payload to the optimizer result. Without
  `:result` it picks the first candidate of every day and slot.
  """

  @behaviour MealPlannerApi.PlanningAgent.Optimizer

  @impl true
  def solve(payload, opts) do
    if pid = Keyword.get(opts, :notify), do: send(pid, {:optimizer_payload, payload})
    if pid = Keyword.get(opts, :notify_opts), do: send(pid, {:optimizer_opts, opts})
    Keyword.get(opts, :result, &first_candidates/1).(payload)
  end

  @doc """
  A plan keeping every fixed meal of the payload and taking the first
  candidate of each slot for every other day and slot.
  """
  def first_candidates(payload) do
    fixed =
      Map.new(payload["fixed_meals"] || [], &{{&1["day"], &1["slot"]}, &1["recipe_id"]})

    meals =
      for day <- payload["days"], slot <- payload["slots"] do
        [first | _] = payload["candidates_by_slot"][slot]
        recipe_id = Map.get(fixed, {day, slot}, first["recipe_id"])
        %{"day" => day, "slot" => slot, "recipe_id" => recipe_id}
      end

    {:ok, %{"meals" => meals}}
  end

  @doc "A plan using `recipe_id` for every day and slot of the payload."
  def everywhere(recipe_id) do
    fn payload ->
      meals =
        for day <- payload["days"], slot <- payload["slots"] do
          %{"day" => day, "slot" => slot, "recipe_id" => recipe_id}
        end

      {:ok, %{"meals" => meals}}
    end
  end
end
