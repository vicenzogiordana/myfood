defmodule MealPlannerApi.PlanningAgent.FakeRecipeSearch do
  @moduledoc """
  Hand-written recipe search fake for planning agent tests.

  Options: `:steps` is an `Agent` holding a list of steps consumed one per
  call — `:fail` (`{:error, :search_failed}`), `{:sleep, ms}` (answers no
  recipes after sleeping) or `{:ok, recipes}`; an exhausted list answers no
  recipes. `:notify` receives `{:recipe_search, filters}` for every call.
  """

  @doc "Starts the step holder for `steps`."
  def steps!(steps) do
    {:ok, agent} = Agent.start_link(fn -> steps end)
    agent
  end

  def search(_household, filters, opts) do
    if pid = Keyword.get(opts, :notify), do: send(pid, {:recipe_search, filters})

    step =
      Agent.get_and_update(Keyword.fetch!(opts, :steps), fn
        [] -> {{:ok, []}, []}
        [step | rest] -> {step, rest}
      end)

    case step do
      :fail ->
        {:error, :search_failed}

      {:sleep, ms} ->
        Process.sleep(ms)
        {:ok, []}

      {:ok, recipes} ->
        {:ok, recipes}
    end
  end
end
