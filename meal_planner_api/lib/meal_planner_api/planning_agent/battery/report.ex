defmodule MealPlannerApi.PlanningAgent.Battery.Report do
  @moduledoc """
  The quality battery report (issue #109, criteria agreed in #87).

  ## Verdict

    * `incomplete` — some planned runs never ran (the spend ceiling was
      reached); a battery that did not run in full never passes. This wins
      over every other verdict; its reasons still name any hard-rule
      violation
    * `fail` — any run presented a hard-rule violation as valid, whatever
      the score; or fewer than 90% of the planned runs are correct, counting
      pooled over every task; or a configured gate failed or could not be
      measured
    * `pending_human_review` — the minimum can only be reached with runs
      left for human review (a criterion configured as human-judged)
    * `pass` — none of the above

  The minimum is `ceil(0.9 * planned_runs)`: 68 of 75, so at most 7 runs may
  fail.

  ## Gates

  Each threshold of `MealPlannerApi.PlanningAgent.Battery.Config` is a gate:

    * `max_cost_micros_per_completed_task` — total spend / correct runs
    * `max_latency_ms_p50`, `max_latency_ms_p95` — nearest-rank percentiles
      of the wall time of the runs that ran
    * `max_questions_per_run` — mean questions per run that ran
    * `min_provenance_coverage` — Purchase lines with full provenance over
      all Purchase lines of the final Proposals
    * `min_escalation_quality` — unsolvable-task runs that named the real
      cause over those judged so far
    * `min_recovery_correctness` — recovery checks that held over all

  Gates are computed only from the runs that ran. A gate without evidence
  is reported as not measured and does not pass.

  ## Not run

  A result with the outcome `:not_run` (a run the spend ceiling refused,
  see `MealPlannerApi.PlanningAgent.Battery`) is listed with its evidence
  but is not a run that ran: it counts under Not run with every planned run
  never started, never in the score or a gate. Its spend, really spent,
  still counts in the total spend.

  A run whose failure the harness caused is listed under `harness_failures`:
  per spec #93 such a failure reopens the architecture decision.
  """

  alias MealPlannerApi.PlanningAgent.Battery.Config

  @minimum_ratio 0.9
  @harness_note "A failure caused by the harness reopens the architecture decision (spec #93)."

  @doc """
  Builds the report from the run results. Options: `:planned_runs` (the
  battery's 15 x 5), `:started_at`, `:finished_at`.
  """
  @spec build(Config.t(), [map()], keyword()) :: map()
  def build(%Config{} = config, results, opts) do
    planned = Keyword.fetch!(opts, :planned_runs)
    # Runs the spend ceiling cut are listed but neither counted nor graded.
    listed = results
    {skipped, results} = Enum.split_with(results, &not_run?/1)
    outcomes = Enum.frequencies_by(results, & &1.grade.outcome)
    count = &Map.get(outcomes, &1, 0)
    correct = count.(:correct)
    pending = count.(:pending_review)
    hard = count.(:hard_violation)
    not_run = max(planned - length(results), 0)
    min_correct = ceil(planned * @minimum_ratio)
    gates = gates(config, results, correct)
    {verdict, reasons} = verdict(hard, not_run, correct, pending, min_correct, gates)

    %{
      "battery" => "planning agent quality battery",
      "spec" => "#93",
      "issue" => "#109",
      "started_at" => stamp(opts[:started_at]),
      "finished_at" => stamp(opts[:finished_at]),
      "config" => Config.to_data(config),
      "summary" => %{
        "planned_runs" => planned,
        "runs" => length(results),
        "correct" => correct,
        "incorrect" => count.(:incorrect),
        "pending_review" => pending,
        "hard_violations" => hard,
        "errors" => count.(:error),
        "not_run" => not_run,
        "score" => ratio(correct, planned),
        "min_correct" => min_correct,
        "spend_micros" => (results ++ skipped) |> Enum.map(& &1.spend_micros) |> Enum.sum(),
        "verdict" => verdict,
        "verdict_reasons" => reasons,
        "harness_note" => @harness_note
      },
      "gates" => gates,
      "harness_failures" =>
        for %{grade: %{harness_failure?: true}} = result <- results do
          %{"task_id" => result.task_id, "run" => result.run, "reasons" => result.grade.reasons}
        end,
      "runs" => Enum.map(listed, &run_data/1)
    }
  end

  defp not_run?(result), do: result.grade.outcome == :not_run

  defp verdict(hard, not_run, correct, pending, min_correct, gates) do
    failed_gates =
      for %{"passed" => false} = gate <- gates do
        if is_nil(gate["measured"]),
          do: "gate #{gate["name"]} not measured",
          else: "gate #{gate["name"]} missed its threshold"
      end

    short = "#{correct} correct runs, #{min_correct} required"
    hard_reason = "#{hard} run#{plural(hard)} presented a hard-rule violation as valid"

    cond do
      not_run > 0 ->
        {"incomplete",
         ["#{not_run} planned runs did not run (spend ceiling reached)"] ++
           if(hard > 0, do: [hard_reason], else: [])}

      hard > 0 ->
        {"fail", [hard_reason]}

      correct + pending < min_correct ->
        {"fail", [short | failed_gates]}

      failed_gates != [] ->
        {"fail", failed_gates}

      correct < min_correct ->
        {"pending_human_review", [short <> "; #{pending} runs pending human review"]}

      true ->
        {"pass", []}
    end
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # ---------------------------------------------------------------------------
  # Gates
  # ---------------------------------------------------------------------------

  defp gates(config, results, correct) do
    latencies = results |> Enum.map(& &1.latency_ms) |> Enum.sort()
    metrics = Enum.map(results, & &1.grade.metrics)
    spend = results |> Enum.map(& &1.spend_micros) |> Enum.sum()

    measured = %{
      max_cost_micros_per_completed_task: if(correct > 0, do: round4(spend / correct)),
      max_latency_ms_p50: percentile(latencies, 0.5),
      max_latency_ms_p95: percentile(latencies, 0.95),
      max_questions_per_run:
        if(results != [],
          do: round4(Enum.sum(Enum.map(metrics, & &1.questions)) / length(results))
        ),
      min_provenance_coverage: pooled(Enum.map(metrics, & &1.provenance)),
      min_escalation_quality: escalation(metrics),
      min_recovery_correctness: pooled(Enum.map(metrics, & &1.recovery))
    }

    for key <- Config.threshold_keys() do
      threshold = Map.fetch!(config.thresholds, key)
      value = Map.fetch!(measured, key)

      %{
        "name" => Atom.to_string(key),
        "threshold" => threshold,
        "measured" => value,
        "passed" => not is_nil(value) and within?(key, value, threshold)
      }
    end
  end

  defp within?(key, value, threshold) do
    if String.starts_with?(Atom.to_string(key), "max_"),
      do: value <= threshold,
      else: value >= threshold
  end

  defp percentile([], _p), do: nil
  defp percentile(sorted, p), do: Enum.at(sorted, max(ceil(p * length(sorted)) - 1, 0))

  defp pooled(pairs) do
    {hit, total} = Enum.reduce(pairs, {0, 0}, fn {h, t}, {hs, ts} -> {hs + h, ts + t} end)
    if total > 0, do: round4(hit / total)
  end

  defp escalation(metrics) do
    judged = for %{escalation: e} <- metrics, is_boolean(e), do: e
    if judged != [], do: round4(Enum.count(judged, & &1) / length(judged))
  end

  defp ratio(_hit, 0), do: 0.0
  defp ratio(hit, total), do: round4(hit / total)
  defp round4(value), do: Float.round(value * 1.0, 4)

  # ---------------------------------------------------------------------------
  # Per-run evidence
  # ---------------------------------------------------------------------------

  defp run_data(result) do
    %{
      "task_id" => result.task_id,
      "title" => result.title,
      "kind" => Atom.to_string(result.kind),
      "solvable" => result.solvable,
      "run" => result.run,
      "outcome" => Atom.to_string(result.grade.outcome),
      "violations" => Enum.map(result.grade.violations, &Atom.to_string/1),
      "reasons" => result.grade.reasons,
      "latency_ms" => result.latency_ms,
      "spend_micros" => result.spend_micros,
      "metrics" => jsonable(result.grade.metrics),
      "evidence" => jsonable(result.evidence)
    }
  end

  defp stamp(nil), do: nil
  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  @doc false
  def jsonable(%{__struct__: _} = struct), do: to_string(struct)

  def jsonable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  def jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  def jsonable(value) when is_boolean(value) or is_nil(value), do: value
  def jsonable(value) when is_atom(value), do: Atom.to_string(value)
  def jsonable(value) when is_binary(value) or is_number(value), do: value
  def jsonable(value), do: inspect(value)

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @doc "Renders the report in the configured evidence format."
  @spec render(map(), :json | :markdown) :: String.t()
  def render(report, :json), do: Jason.encode!(report, pretty: true)

  def render(report, :markdown) do
    summary = report["summary"]

    [
      "# Planning agent quality battery",
      "",
      "Spec #{report["spec"]}, issue #{report["issue"]}. Started #{report["started_at"] || "-"}, " <>
        "finished #{report["finished_at"] || "-"}.",
      "",
      "**Verdict: #{String.upcase(summary["verdict"])}**",
      "",
      Enum.map(summary["verdict_reasons"], &"- #{&1}\n"),
      "",
      "## Summary",
      "",
      "| Planned | Ran | Correct | Required | Incorrect | Pending review | Hard violations | Errors | Not run | Score | Spend (micro-USD) |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
      "| #{summary["planned_runs"]} | #{summary["runs"]} | #{summary["correct"]} | " <>
        "#{summary["min_correct"]} | #{summary["incorrect"]} | #{summary["pending_review"]} | " <>
        "#{summary["hard_violations"]} | #{summary["errors"]} | #{summary["not_run"]} | " <>
        "#{summary["score"]} | #{summary["spend_micros"]} |",
      "",
      "## Gates",
      "",
      "| Gate | Threshold | Measured | Passed |",
      "| --- | --- | --- | --- |",
      Enum.map(report["gates"], fn gate ->
        "| #{gate["name"]} | #{gate["threshold"]} | #{cell(gate["measured"])} | #{gate["passed"]} |\n"
      end),
      "",
      "## Configuration",
      "",
      "```json",
      Jason.encode!(report["config"], pretty: true),
      "```",
      "",
      "## Harness failures",
      "",
      summary["harness_note"],
      "",
      case report["harness_failures"] do
        [] ->
          "None.\n"

        failures ->
          Enum.map(
            failures,
            &"- #{&1["task_id"]} run #{&1["run"]}: #{Enum.join(&1["reasons"], "; ")}\n"
          )
      end,
      "",
      "## Runs",
      "",
      "| Task | Run | Kind | Solvable | Outcome | Violations | Reasons | Latency (ms) | Spend (micro-USD) |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
      Enum.map(report["runs"], fn run ->
        "| #{run["task_id"]} | #{run["run"]} | #{run["kind"]} | #{run["solvable"]} | " <>
          "#{run["outcome"]} | #{cell(Enum.join(run["violations"], ", "))} | " <>
          "#{cell(Enum.join(run["reasons"], "; "))} | #{run["latency_ms"]} | #{run["spend_micros"]} |\n"
      end),
      "",
      "## Run evidence",
      "",
      Enum.map(report["runs"], fn run ->
        "### #{run["task_id"]} run #{run["run"]}: #{run["title"]}\n\n```json\n" <>
          Jason.encode!(%{"metrics" => run["metrics"], "evidence" => run["evidence"]},
            pretty: true
          ) <>
          "\n```\n\n"
      end)
    ]
    |> Enum.map(&line/1)
    |> IO.iodata_to_binary()
  end

  defp line(text) when is_binary(text), do: [text, "\n"]
  defp line(iodata), do: iodata

  defp cell(nil), do: "-"
  defp cell(""), do: "-"
  defp cell(value) when is_binary(value), do: String.replace(value, ["|", "\n"], " ")
  defp cell(value), do: to_string(value)
end
