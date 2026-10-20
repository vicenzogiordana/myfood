defmodule MealPlannerApi.PlanningAgent.Battery.Run do
  @moduledoc """
  One run of one battery task (issue #109) through the planning agent
  session module (spec #93, seam 1).

  The run builds the task's fixtures inside a database sandbox owned by the
  run, starts a Planning Session as the Household's Owner, plays the
  fictitious Member's steps (messages and confirmations), collects what the
  Member was shown and what was saved, ends the session and rolls every
  write back. The grader then judges the evidence
  (`MealPlannerApi.PlanningAgent.Battery.Grader`).

  The Member never authorizes a continuation after a limit and never
  approves a Deviation or an Absence Exception: the battery measures what
  the agent does on its own.
  """

  alias Ecto.Adapters.SQL.Sandbox

  alias MealPlannerApi.PlanningAgent.Battery.{
    FailingRecipeSearch,
    Grader,
    Kitchen,
    MeteredModel,
    PreparedScraper,
    Task,
    Tasks
  }

  alias MealPlannerApi.PlanningAgent.Optimizer.Unavailable
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @supervisor MealPlannerApi.PlanningAgent.SessionSupervisor
  # Beyond the session's own request deadline, so the session always ends a
  # run before the battery gives up on it.
  @wait_margin_ms 30_000
  @default_deadline_ms 5 * 60 * 1000

  @doc """
  Runs `task` once as run number `run`. `ctx` holds `:model` (`{module,
  opts}` for this run), `:optimizer`, `:judges`, `:meter`,
  `:session_opts` and `:ceiling_capped` (whether the run's spend cap is the
  battery's remaining ceiling).

  A run whose model call the ceiling refused (`:ceiling_capped` and a
  `session_budget_exhausted` event with limit `spend_cap`) never reached
  the model in full: it is recorded with the outcome `:not_run`, never
  graded.
  """
  @spec execute(Task.t(), pos_integer(), map()) :: map()
  def execute(%Task{} = task, run, ctx) do
    key = {task.id, run}
    evidence = isolated(fn -> drive(task, key, ctx) end)
    spend = Agent.get(ctx.meter, &Map.get(&1, key, 0))

    %{
      task_id: task.id,
      title: task.title,
      kind: task.kind,
      solvable: task.solvable,
      run: run,
      latency_ms: evidence.latency_ms,
      spend_micros: spend,
      grade: grade(task, evidence, ctx),
      evidence: summary(evidence)
    }
  end

  defp grade(task, evidence, ctx) do
    if Map.get(ctx, :ceiling_capped, false) and "spend_cap" in evidence.exhausted do
      %{
        outcome: :not_run,
        violations: [],
        reasons: ["the spend ceiling refused a model call"],
        harness_failure?: false,
        metrics: nil
      }
    else
      Grader.grade(task, evidence, ctx.judges)
    end
  end

  @doc """
  Runs `fun` with its own sandboxed connection, rolled back afterwards. The
  battery runs one session at a time, so every Planning Session still alive
  when `fun` returns is the run's own and is shut down first.
  """
  @spec isolated((-> result)) :: result when result: var
  def isolated(fun) do
    owner = Sandbox.start_owner!(Repo, shared: true)

    try do
      fun.()
    after
      # No session process may outlive the sandbox it writes through.
      for {_, pid, _, _} <- DynamicSupervisor.which_children(@supervisor), is_pid(pid) do
        DynamicSupervisor.terminate_child(@supervisor, pid)
      end

      Sandbox.stop_owner(owner)
    end
  end

  # ---------------------------------------------------------------------------
  # Driving the session
  # ---------------------------------------------------------------------------

  defp drive(task, key, ctx) do
    kitchen = Kitchen.build(task.kitchen)
    base = base_evidence(kitchen)

    case Session.start(attrs(kitchen), session_opts(task, key, ctx)) do
      {:ok, %{session_id: session_id, pid: pid}} ->
        started = System.monotonic_time(:millisecond)

        wait_ms =
          Keyword.get(ctx.session_opts, :deadline_ms, @default_deadline_ms) + @wait_margin_ms

        state =
          Enum.reduce(task.steps, initial_state(), fn step, state ->
            step(step, state, %{
              kitchen: kitchen,
              session_id: session_id,
              pid: pid,
              wait_ms: wait_ms
            })
          end)

        latency = System.monotonic_time(:millisecond) - started
        saved = Kitchen.saved(kitchen)
        end_session(pid)
        events = state.events ++ drain(session_id)

        base
        |> Map.merge(from_events(events))
        |> Map.merge(%{
          current_proposal: state.current,
          confirmations: Enum.reverse(state.confirmations),
          saved: saved,
          harness_errors: Enum.reverse(state.errors),
          notes: Enum.reverse(state.notes),
          latency_ms: latency
        })

      {:error, reason} ->
        %{base | harness_errors: ["session start refused: #{inspect(reason)}"]}
    end
  rescue
    exception ->
      Map.merge(base_evidence(nil), %{
        harness_errors: ["runner error: " <> Exception.message(exception)]
      })
  end

  defp attrs(kitchen) do
    %{
      account_id: kitchen.account_id,
      user_id: kitchen.owner.user_id,
      membership_id: kitchen.owner.membership_id,
      role: :owner,
      range: kitchen.range,
      slots: kitchen.slots
    }
  end

  defp session_opts(task, key, ctx) do
    tools = task.tools

    [
      model: {MeteredModel, inner: ctx.model, meter: ctx.meter, run: key},
      optimizer:
        if(tools[:optimizer] == :unavailable, do: {Unavailable, []}, else: ctx.optimizer),
      price_scraper: {PreparedScraper, scraper_opts(tools[:scraper])},
      clock: &Tasks.now/0,
      subscriber: self(),
      # Every run plans a fresh Household that starts exactly one session.
      session_start_limit: {1, 3_600}
    ]
    |> then(fn opts ->
      if tools[:recipe_search] == :failing,
        do: Keyword.put(opts, :recipe_search, {FailingRecipeSearch, []}),
        else: opts
    end)
    |> Keyword.merge(ctx.session_opts)
  end

  defp scraper_opts(nil), do: []
  defp scraper_opts(scraper), do: Enum.into(scraper, [])

  defp initial_state,
    do: %{events: [], current: nil, confirmations: [], errors: [], notes: [], halted: false}

  defp step({:message, _text}, %{halted: true} = state, _run), do: state

  defp step({:message, text}, state, run) do
    case Session.send_message(run.pid, text) do
      :ok ->
        state = collect(state, run)

        case Enum.find(state.events, &(&1["type"] == "session_budget_exhausted")) do
          nil ->
            %{state | current: Session.current_proposal(run.pid) || state.current}

          # The session may already have ended: its last Proposal comes with
          # the event, and no later message is sent.
          exhausted ->
            %{
              state
              | current: exhausted["proposal"] || state.current,
                halted: true,
                notes: ["session budget exhausted: #{exhausted["limit"]}" | state.notes]
            }
        end

      {:error, :session_budget_exhausted} ->
        %{
          state
          | halted: true,
            notes: ["message not sent: session budget exhausted" | state.notes]
        }

      {:error, :authorization_required} ->
        # A limit stopped the run and the Member never authorizes more.
        %{state | halted: true, notes: ["message not sent: authorization required" | state.notes]}

      {:error, reason} ->
        %{state | errors: ["message refused: #{inspect(reason)}" | state.errors]}
    end
  end

  defp step({:confirm, :current}, state, run), do: confirm(state, run, current_id(state), false)

  defp step({:confirm_twice, :current}, state, run) do
    id = current_id(state)
    state |> confirm(run, id, false) |> confirm(run, id, false)
  end

  defp step({:confirm, :first}, state, run) do
    first = Enum.find(state.events, &(&1["type"] == "proposal"))
    current = current_id(state)

    if first && first["proposal_id"] != current do
      confirm(state, run, first["proposal_id"], true)
    else
      %{state | notes: ["no replaced Proposal to confirm" | state.notes]}
    end
  end

  defp current_id(%{current: nil}), do: nil
  defp current_id(%{current: current}), do: current["proposal_id"]

  defp confirm(state, _run, nil, stale) do
    entry = %{proposal_id: nil, stale: stale, result: {:error, :no_proposal}}
    %{state | confirmations: [entry | state.confirmations]}
  end

  defp confirm(state, run, proposal_id, stale) do
    result =
      Session.confirm(run.kitchen.account_id, run.kitchen.owner.membership_id, proposal_id)

    entry = %{proposal_id: proposal_id, stale: stale, result: result}
    %{state | confirmations: [entry | state.confirmations]}
  end

  defp collect(state, run) do
    deadline = System.monotonic_time(:millisecond) + run.wait_ms
    collect(state, run.session_id, deadline)
  end

  defp collect(state, session_id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:planning_agent_event, ^session_id, %{"type" => "run_finished"} = event} ->
        %{state | events: state.events ++ [event]}

      {:planning_agent_event, ^session_id, event} ->
        collect(%{state | events: state.events ++ [event]}, session_id, deadline)
    after
      remaining ->
        %{state | errors: ["no run_finished before the battery's wait ended" | state.errors]}
    end
  end

  defp drain(session_id) do
    receive do
      {:planning_agent_event, ^session_id, event} -> [event | drain(session_id)]
    after
      0 -> []
    end
  end

  defp end_session(pid) do
    _ = DynamicSupervisor.terminate_child(@supervisor, pid)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Evidence
  # ---------------------------------------------------------------------------

  defp base_evidence(kitchen) do
    %{
      forbidden_recipe_ids: (kitchen && kitchen.forbidden_recipe_ids) || MapSet.new(),
      recipe_ingredients: (kitchen && kitchen.recipe_ingredients) || %{},
      ingredient_names: (kitchen && kitchen.ingredient_names) || %{},
      proposals: [],
      current_proposal: nil,
      questions: [],
      messages: [],
      limits: [],
      run_outcomes: [],
      unavailable: [],
      exhausted: [],
      event_types: [],
      confirmations: [],
      saved: %{planned_meals: 0, shopping_lines: 0, household_recipes: 0},
      harness_errors: [],
      notes: [],
      latency_ms: 0
    }
  end

  defp from_events(events) do
    of = fn type -> Enum.filter(events, &(&1["type"] == type)) end

    %{
      proposals: of.("proposal"),
      questions: Enum.map(of.("question"), & &1["text"]),
      messages: Enum.map(of.("assistant_message"), & &1["text"]),
      limits: Enum.map(of.("limit_reached"), & &1["limit"]),
      run_outcomes: Enum.map(of.("run_finished"), & &1["outcome"]),
      unavailable: Enum.map(of.("agent_unavailable"), & &1["reason"]),
      exhausted: Enum.map(of.("session_budget_exhausted"), & &1["limit"]),
      event_types: Enum.map(events, & &1["type"])
    }
  end

  # What the report keeps of a run: what the Member saw and what was saved.
  defp summary(evidence) do
    %{
      proposals: Enum.map(evidence.proposals, &proposal_summary/1),
      final_proposal_id: evidence.current_proposal && evidence.current_proposal["proposal_id"],
      final_status: evidence.current_proposal && evidence.current_proposal["status"],
      questions: evidence.questions,
      messages: evidence.messages,
      limits: evidence.limits,
      run_outcomes: evidence.run_outcomes,
      unavailable: evidence.unavailable,
      event_types: evidence.event_types,
      confirmations:
        Enum.map(evidence.confirmations, fn c ->
          %{proposal_id: c.proposal_id, stale: c.stale, result: inspect(c.result)}
        end),
      saved: evidence.saved,
      notes: evidence.notes
    }
  end

  defp proposal_summary(proposal) do
    %{
      proposal_id: proposal["proposal_id"],
      status: proposal["status"],
      meals:
        Enum.map(proposal["meals"] || [], fn meal ->
          "#{meal["date"]} #{meal["slot"]}: #{meal["name"]} (#{meal["recipe_id"]})"
        end),
      purchase_total_cents: get_in(proposal, ["purchase", "total_cents"]),
      missing_prices: length(get_in(proposal, ["purchase", "missing_prices"]) || []),
      stale_prices: length(get_in(proposal, ["purchase", "stale_prices"]) || []),
      budget: proposal["budget"],
      deviations: proposal["deviations"]
    }
  end
end
