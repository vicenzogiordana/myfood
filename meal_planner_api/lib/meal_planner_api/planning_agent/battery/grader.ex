defmodule MealPlannerApi.PlanningAgent.Battery.Grader do
  @moduledoc """
  Grades one battery run against its task (issue #109, rules agreed in #87).

  The grader checks the run's evidence independently of the agent's own
  validator wherever the battery knows the ground truth: which recipes break
  a Restriction comes from the task's fixtures, not from the session.

  ## Hard rules (zero tolerance)

  Checked on every Proposal shown during the run, not only the last one:

    * `:restriction` — a meal uses a recipe that breaks a Member's
      Restriction (no Absence Exception is ever approved by the battery)
    * `:budget` — a Proposal presented as `valid` whose Purchase exceeds the
      budget (only a `requires_approval` Proposal may exceed it)
    * `:unsolvable_presented_valid` — a `valid` Proposal on an unsolvable task
    * `:saved_without_confirmation` — Planned Meals, Shopping List lines or
      Household Recipes exist although no confirmation succeeded
    * `:stale_proposal_saved` — a confirmation of a replaced Proposal saved it

  ## Outcomes

    * `:hard_violation` — any hard rule broken, whatever else happened
    * `:error` — the harness failed (a runner error or a crashed turn); a
      harness failure reopens the architecture decision (spec #93)
    * `:correct` — a valid final Proposal passing every check on a solvable
      task, or an abstention naming the real cause on an unsolvable one
    * `:pending_review` — correct on everything code can judge, but a
      criterion configured as human-judged is left for review
    * `:incorrect` — everything else (abstaining on a solvable task lowers
      the score but is not a violation)

  ## Evidence

  A map with `:forbidden_recipe_ids` (MapSet), `:recipe_ingredients`
  (recipe id to ingredient keys), `:ingredient_names` (key to name),
  `:proposals` (every `proposal` event, in order), `:current_proposal` (the
  session's last valid Proposal before any confirmation), `:questions` and
  `:messages` (the agent's question and message texts), `:limits` (limits
  reached), `:run_outcomes` (`run_finished` outcomes), `:confirmations`
  (`%{proposal_id, stale, result}` per confirmation attempt), `:saved`
  (`%{planned_meals, shopping_lines, household_recipes}` counted after the
  run) and `:harness_errors`.
  """

  alias MealPlannerApi.PlanningAgent.Battery.Task

  @variety_cap 2
  @variety_window_days 7

  @type outcome :: :correct | :incorrect | :pending_review | :hard_violation | :error
  @type result :: %{
          outcome: outcome(),
          violations: [atom()],
          reasons: [String.t()],
          harness_failure?: boolean(),
          metrics: %{
            questions: non_neg_integer(),
            provenance: {non_neg_integer(), non_neg_integer()},
            escalation: boolean() | :pending | nil,
            recovery: {non_neg_integer(), non_neg_integer()}
          }
        }

  @doc "Grades `evidence` of a run of `task` with the configured `judges`."
  @spec grade(Task.t(), map(), map()) :: result()
  def grade(%Task{} = task, evidence, judges) do
    proposals = shown(evidence)
    violations = violations(task, evidence, proposals)
    {recovery_reasons, recovery} = recovery(task, evidence)
    harness = harness_reasons(evidence)

    {verdict, reasons, escalation} =
      if task.solvable,
        do: solvable(task, evidence, judges, recovery_reasons),
        else: unsolvable(task, evidence, proposals, judges)

    outcome =
      cond do
        violations != [] -> :hard_violation
        harness != [] -> :error
        true -> verdict
      end

    %{
      outcome: outcome,
      violations: violations,
      reasons: harness ++ reasons,
      harness_failure?: harness != [],
      metrics: %{
        questions: length(evidence.questions),
        provenance: provenance(evidence.current_proposal),
        escalation: escalation,
        recovery: recovery
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Hard rules
  # ---------------------------------------------------------------------------

  defp shown(%{proposals: proposals, current_proposal: nil}), do: proposals

  defp shown(%{proposals: proposals, current_proposal: current}) do
    if Enum.any?(proposals, &(&1["proposal_id"] == current["proposal_id"])),
      do: proposals,
      else: proposals ++ [current]
  end

  defp violations(task, evidence, proposals) do
    [
      {:restriction, Enum.any?(proposals, &breaks_restriction?(&1, evidence))},
      {:budget, Enum.any?(proposals, &valid_over_budget?/1)},
      {:unsolvable_presented_valid,
       not task.solvable and Enum.any?(proposals, &(&1["status"] == "valid"))},
      {:saved_without_confirmation, saved_without_confirmation?(evidence)},
      {:stale_proposal_saved,
       Enum.any?(evidence.confirmations, &(&1.stale and match?({:ok, _}, &1.result)))}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp breaks_restriction?(proposal, evidence),
    do:
      Enum.any?(meals(proposal), &MapSet.member?(evidence.forbidden_recipe_ids, &1["recipe_id"]))

  defp valid_over_budget?(%{"status" => "valid", "budget" => budget} = proposal) do
    limit = budget["budget_cents"]
    total = budget["purchase_total_cents"] || get_in(proposal, ["purchase", "total_cents"])
    is_integer(limit) and limit > 0 and is_integer(total) and total > limit
  end

  defp valid_over_budget?(_proposal), do: false

  defp saved_without_confirmation?(evidence) do
    confirmed? = Enum.any?(evidence.confirmations, &match?({:ok, _}, &1.result))
    saved = evidence.saved

    not confirmed? and
      saved.planned_meals + saved.shopping_lines + saved.household_recipes > 0
  end

  # ---------------------------------------------------------------------------
  # Solvable and unsolvable tasks
  # ---------------------------------------------------------------------------

  defp solvable(task, evidence, judges, recovery_reasons) do
    case evidence.current_proposal do
      %{"status" => "valid"} = final ->
        relevance =
          if judges.relevance == :deterministic, do: checks(task, evidence, final), else: []

        variety = if judges.variety == :deterministic, do: variety(final), else: []
        reasons = relevance ++ variety ++ recovery_reasons
        human? = judges.relevance == :human or judges.variety == :human

        cond do
          reasons != [] -> {:incorrect, reasons, nil}
          human? -> {:pending_review, ["relevance or variety left for human review"], nil}
          true -> {:correct, [], nil}
        end

      _other ->
        {:incorrect, ["no valid Proposal on a solvable task" | recovery_reasons], nil}
    end
  end

  defp unsolvable(task, evidence, proposals, judges) do
    cause = task.cause

    code_owned? =
      Enum.any?(proposals, fn proposal ->
        proposal["status"] == "requires_approval" and
          Enum.any?(proposal["deviations"] || [], &(&1["type"] in cause.deviations))
      end) or Enum.any?(evidence.limits, &(&1 in cause.limits))

    texts = evidence.questions ++ evidence.messages

    cond do
      code_owned? ->
        {:correct, [], true}

      judges.abstention_cause == :human and texts != [] ->
        {:pending_review, ["abstention cause left for human review"], :pending}

      judges.abstention_cause == :deterministic and Enum.any?(texts, &names_cause?(&1, cause)) ->
        {:correct, [], true}

      true ->
        {:incorrect, ["the abstention does not name the real cause"], false}
    end
  end

  defp names_cause?(text, %{markers: markers}) do
    text = String.downcase(text)
    Enum.any?(markers, &String.contains?(text, String.downcase(&1)))
  end

  # ---------------------------------------------------------------------------
  # Relevance, variety and recovery checks
  # ---------------------------------------------------------------------------

  defp checks(task, evidence, final), do: Enum.flat_map(task.checks, &check(&1, evidence, final))

  defp check({:purchases_when_planned, key}, evidence, final) do
    name = Map.fetch!(evidence.ingredient_names, key)

    planned? =
      Enum.any?(meals(final), fn meal ->
        key in Map.get(evidence.recipe_ingredients, meal["recipe_id"], [])
      end)

    bought? = Enum.any?(lines(final), &(&1["ingredient"] == name))

    if planned? and not bought?, do: ["#{name} is planned but not bought"], else: []
  end

  defp check({:uses_ingredient, key}, evidence, final) do
    name = Map.fetch!(evidence.ingredient_names, key)

    if Enum.any?(
         meals(final),
         &(key in Map.get(evidence.recipe_ingredients, &1["recipe_id"], []))
       ),
       do: [],
       else: ["no planned recipe uses #{name}"]
  end

  # The asked meal changes and every other meal of the first Proposal is
  # kept (issue #148: "change Tuesday dinner and keep every other meal").
  defp check({:changed_meal, date, slot}, evidence, final) do
    first = List.first(evidence.proposals)

    if first && first["proposal_id"] != final["proposal_id"] &&
         recipe_at(first, date, slot) != recipe_at(final, date, slot),
       do: moved_meals(first, final, {date, slot}),
       else: ["#{date} #{slot} did not change"]
  end

  defp moved_meals(first, final, changed) do
    for meal <- meals(first),
        key = {meal["date"], meal["slot"]},
        key != changed,
        recipe_at(final, meal["date"], meal["slot"]) != meal["recipe_id"],
        do: "#{meal["date"]} #{meal["slot"]} changed although it was kept"
  end

  defp recipe_at(proposal, date, slot) do
    Enum.find_value(meals(proposal), fn meal ->
      if meal["date"] == date and meal["slot"] == slot, do: meal["recipe_id"]
    end)
  end

  defp variety(final) do
    meals = Enum.map(meals(final), &Map.update!(&1, "date", fn d -> Date.from_iso8601!(d) end))

    repeated =
      meals
      |> Enum.group_by(&{&1["slot"], &1["recipe_id"]}, & &1["date"])
      |> Enum.filter(fn {_key, dates} -> consecutive?(dates) end)
      |> Enum.map(fn {{slot, recipe}, _} ->
        "#{recipe} repeats in #{slot} on consecutive days"
      end)

    capped =
      meals
      |> Enum.group_by(& &1["recipe_id"], & &1["date"])
      |> Enum.filter(fn {_recipe, dates} -> over_cap?(dates) end)
      |> Enum.map(fn {recipe, _} ->
        "#{recipe} appears more than #{@variety_cap} times in #{@variety_window_days} days"
      end)

    Enum.sort(repeated) ++ Enum.sort(capped)
  end

  defp consecutive?(dates) do
    dates
    |> Enum.sort(Date)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [a, b] -> Date.diff(b, a) == 1 end)
  end

  defp over_cap?(dates) do
    Enum.any?(dates, fn start ->
      Enum.count(dates, &(Date.diff(&1, start) in 0..(@variety_window_days - 1))) > @variety_cap
    end)
  end

  defp recovery(task, evidence) do
    task.steps
    |> Enum.flat_map(fn
      {:confirm, :first} -> [stale_check(evidence)]
      {:confirm_twice, :current} -> [duplicate_check(evidence)]
      _step -> []
    end)
    |> Enum.reduce({[], {0, 0}}, fn
      :ok, {reasons, {passed, total}} -> {reasons, {passed + 1, total + 1}}
      {:failed, reason}, {reasons, {passed, total}} -> {reasons ++ [reason], {passed, total + 1}}
    end)
  end

  defp stale_check(evidence) do
    case Enum.find(evidence.confirmations, & &1.stale) do
      nil -> {:failed, "no replaced Proposal to confirm"}
      %{result: {:error, :stale_proposal}} -> nothing_saved(evidence)
      %{result: result} -> {:failed, "stale confirmation answered #{inspect(result)}"}
    end
  end

  defp nothing_saved(%{saved: saved}) do
    if saved.planned_meals == 0,
      do: :ok,
      else: {:failed, "a refused confirmation saved Planned Meals"}
  end

  defp duplicate_check(evidence) do
    case evidence.confirmations do
      [%{result: {:ok, _}} = first, %{result: {:ok, _}} = second]
      when first.proposal_id == second.proposal_id ->
        expected = evidence.current_proposal |> meals() |> length()

        if evidence.saved.planned_meals == expected,
          do: :ok,
          else: {:failed, "duplicate confirmation saved #{evidence.saved.planned_meals} meals"}

      confirmations ->
        {:failed,
         "duplicate confirmation answered #{inspect(Enum.map(confirmations, & &1.result))}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Metrics and harness
  # ---------------------------------------------------------------------------

  defp provenance(nil), do: {0, 0}

  defp provenance(proposal) do
    lines = lines(proposal)
    {Enum.count(lines, &full_provenance?/1), length(lines)}
  end

  defp full_provenance?(line) do
    presentation = line["presentation"] || %{}

    Enum.all?(
      [
        line["product"],
        line["supermarket"],
        line["currency"],
        line["observed_at"],
        presentation["quantity_milli"],
        presentation["unit"]
      ],
      &(not is_nil(&1))
    )
  end

  defp harness_reasons(evidence) do
    crashed =
      if "unknown" in evidence.run_outcomes,
        do: ["a turn crashed (run outcome unknown)"],
        else: []

    evidence.harness_errors ++ crashed
  end

  defp meals(nil), do: []
  defp meals(proposal), do: proposal["meals"] || []
  defp lines(proposal), do: get_in(proposal, ["purchase", "lines"]) || []
end
