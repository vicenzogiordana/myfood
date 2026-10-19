defmodule MealPlannerApi.PlanningAgent.Battery do
  @moduledoc """
  The planning agent's pre-launch quality battery (spec #93 user stories
  107-109, issue #109, criteria agreed in #87).

  It runs the 15 tasks of `MealPlannerApi.PlanningAgent.Battery.Tasks` five
  times each through the planning agent session module with the configured
  model adapter, fictitious fixtures and prepared recipe and price
  responses, grades every run (`MealPlannerApi.PlanningAgent.Battery.Grader`)
  and builds the pass/fail report
  (`MealPlannerApi.PlanningAgent.Battery.Report`). Run it with
  `mix planning_agent.battery`.

  ## Refusals

  `run/2` refuses before any session starts:

    * `{:unconfigured, problems}` — the spend ceiling or a #87 deferred
      criterion is missing (`MealPlannerApi.PlanningAgent.Battery.Config`);
      they are human decisions with no default
    * `:sandbox_required` — the repository does not use the SQL sandbox
      pool. Every run writes its fixtures inside a sandbox that is rolled
      back, so the battery runs only where the pool allows it
      (`MIX_ENV=test`) and never against real data
    * `:catalog_not_empty` — the database already holds recipes, so the
      fixtures would not be the only data the agent sees
    * `{:model_unconfigured, reason}` — the model adapter refused to start
      (for the paid adapter: missing caps, pricing or API key)

  ## Spend ceiling

  The battery's spend ceiling bounds all runs together. Before each run the
  model adapter's own per-session spend cap (`:spend_cap_micros`) is lowered
  to what is left of the ceiling, so no run can spend past it; once nothing
  is left the remaining runs are not run and the report is `incomplete`.
  """

  alias MealPlannerApi.PlanningAgent.Battery.{Config, Kitchen, Report, Run, Tasks}
  alias MealPlannerApi.Repo

  @runs_per_task 5

  @doc """
  Runs the battery with the decoded configuration `config`.

  ## Options

    * `:model` — `{module, opts}` of the model adapter (required). Offline
      tests may pass a 2-arity function from the task and the run number to
      `{module, opts}`, to script each task
    * `:optimizer` — `{module, opts}` of the optimizer (required)
    * `:runs_per_task` — default 5, as agreed in #87
    * `:tasks` — default `MealPlannerApi.PlanningAgent.Battery.Tasks.all/0`
    * `:session_opts` — extra `MealPlannerApi.PlanningAgent.Session.start/2`
      options, such as `:deadline_ms`
    * `:on_run` — 1-arity function told every run result as it finishes
  """
  @spec run(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(config, opts) do
    tasks = Keyword.get(opts, :tasks, Tasks.all())
    runs = Keyword.get(opts, :runs_per_task, @runs_per_task)
    model = Keyword.fetch!(opts, :model)

    with {:ok, config} <- Config.validate(config),
         :ok <- sandboxed(),
         :ok <- catalog_empty(),
         :ok <- preflight(model_for(model, hd(tasks), 1), config.spend_ceiling_micros) do
      {:ok, meter} = Agent.start_link(fn -> %{} end)
      started_at = DateTime.utc_now()

      ctx = %{
        optimizer: Keyword.fetch!(opts, :optimizer),
        judges: config.judges,
        meter: meter,
        session_opts: Keyword.get(opts, :session_opts, [])
      }

      on_run = Keyword.get(opts, :on_run, fn _result -> :ok end)
      plan = for task <- tasks, run <- 1..runs, do: {task, run}

      results =
        Enum.reduce_while(plan, [], fn {task, run}, results ->
          remaining = config.spend_ceiling_micros - spent(meter)

          if remaining > 0 do
            run_model = cap_spend(model_for(model, task, run), remaining)
            result = Run.execute(task, run, Map.put(ctx, :model, run_model))
            on_run.(result)
            {:cont, [result | results]}
          else
            {:halt, results}
          end
        end)

      Agent.stop(meter)

      {:ok,
       Report.build(config, Enum.reverse(results),
         planned_runs: length(plan),
         started_at: started_at,
         finished_at: DateTime.utc_now()
       )}
    end
  end

  @doc """
  `{module, opts}` with the adapter's per-session spend cap lowered to
  `remaining` micro-USD. The cap comes from `opts`, else the adapter's
  application config; an adapter without a cap keeps none, so a paid
  adapter still refuses to start.
  """
  @spec cap_spend({module(), keyword()}, pos_integer()) :: {module(), keyword()}
  def cap_spend({module, opts}, remaining) do
    configured =
      Keyword.get_lazy(opts, :spend_cap_micros, fn ->
        :meal_planner_api |> Application.get_env(module, []) |> Keyword.get(:spend_cap_micros)
      end)

    if is_integer(configured) and configured > 0,
      do: {module, Keyword.put(opts, :spend_cap_micros, min(configured, remaining))},
      else: {module, opts}
  end

  defp model_for(model, task, run) when is_function(model, 2), do: model.(task, run)
  defp model_for({_module, _opts} = model, _task, _run), do: model

  defp spent(meter), do: meter |> Agent.get(& &1) |> Map.values() |> Enum.sum()

  defp sandboxed do
    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
      do: :ok,
      else: {:error, :sandbox_required}
  end

  defp catalog_empty do
    if Run.isolated(&Kitchen.catalog_empty?/0), do: :ok, else: {:error, :catalog_not_empty}
  end

  defp preflight(model, ceiling) do
    {module, opts} = cap_spend(model, ceiling)

    case module.init(opts) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, {:model_unconfigured, reason}}
    end
  end
end
