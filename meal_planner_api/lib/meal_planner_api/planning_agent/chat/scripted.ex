defmodule MealPlannerApi.PlanningAgent.Chat.Scripted do
  @moduledoc """
  The offline doubles of `mix planning_agent.chat --scripted`: a script for
  the deterministic model adapter
  (`MealPlannerApi.PlanningAgent.Model.Scripted`) and a greedy optimizer, so
  the chat runs end to end with no provider key, no spend and no Python.

  The first Member message builds and presents a plan; every later message
  gets a fixed scripted reply.
  """

  @behaviour MealPlannerApi.PlanningAgent.Optimizer

  @replies 50

  @doc "The scripted model adapter with its script."
  @spec model() :: {module(), keyword()}
  def model do
    {MealPlannerApi.PlanningAgent.Model.Scripted, script: script()}
  end

  @doc "The script: plan and present on the first message, then fixed replies."
  @spec script() :: list()
  def script do
    [
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:text, "(scripted) Here is a plan for the week. Tell me what to change."}
    ] ++ List.duplicate({:text, "(scripted) Noted. This scripted agent cannot replan."}, @replies)
  end

  @doc """
  A greedy plan: every fixed meal kept, every free day and slot filled with
  the least used candidate not served on the previous day in that slot.
  """
  @impl true
  def solve(payload, _opts) do
    fixed =
      Enum.map(payload["fixed_meals"] || [], &{{&1["day"], &1["slot"]}, &1["recipe_id"]})

    fixed_keys = MapSet.new(fixed, &elem(&1, 0))

    {meals, _uses} =
      for(day <- payload["days"], slot <- payload["slots"], do: {day, slot})
      |> Enum.reduce({Map.new(fixed), count(fixed)}, fn {day, slot} = key, {meals, uses} ->
        if MapSet.member?(fixed_keys, key) do
          {meals, uses}
        else
          previous =
            Map.get(meals, {Date.to_iso8601(Date.add(Date.from_iso8601!(day), -1)), slot})

          recipe_id =
            payload["candidates_by_slot"][slot]
            |> Enum.map(& &1["recipe_id"])
            |> Enum.reject(&(&1 == previous))
            |> Enum.min_by(&Map.get(uses, &1, 0))

          {Map.put(meals, key, recipe_id), Map.update(uses, recipe_id, 1, &(&1 + 1))}
        end
      end)

    {:ok,
     %{
       "meals" =>
         meals
         |> Enum.sort()
         |> Enum.map(fn {{day, slot}, id} ->
           %{"day" => day, "slot" => slot, "recipe_id" => id}
         end)
     }}
  end

  defp count(fixed), do: Enum.frequencies_by(fixed, &elem(&1, 1))
end
