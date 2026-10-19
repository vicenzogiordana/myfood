defmodule MealPlannerApi.PlanningAgent.Battery.ReportTest do
  @moduledoc """
  The battery report (issue #109): pooled score with the 90% minimum, zero
  tolerance for hard-rule violations, the configured #87 gates, harness
  failures and per-run evidence, rendered as JSON or Markdown.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.Battery.{Config, Report}
  alias MealPlannerApi.PlanningAgent.BatteryFixtures

  defp config do
    {:ok, config} =
      BatteryFixtures.config_map()
      |> put_in(["thresholds"], %{
        "max_cost_micros_per_completed_task" => 100,
        "max_latency_ms_p50" => 1_000,
        "max_latency_ms_p95" => 2_000,
        "max_questions_per_run" => 1,
        "min_provenance_coverage" => 0.5,
        "min_escalation_quality" => 0.5,
        "min_recovery_correctness" => 0.5
      })
      |> Config.validate()

    config
  end

  defp run(index, outcome, attrs) do
    metrics =
      Map.merge(
        %{questions: 0, provenance: {1, 1}, escalation: true, recovery: {1, 1}},
        Map.get(attrs, :metrics, %{})
      )

    %{
      task_id: Map.get(attrs, :task_id, "T#{rem(index, 15) + 1}"),
      title: "Fictitious task",
      kind: :routine,
      solvable: true,
      run: div(index, 15) + 1,
      latency_ms: Map.get(attrs, :latency_ms, 100),
      spend_micros: Map.get(attrs, :spend_micros, 0),
      grade: %{
        outcome: outcome,
        violations: Map.get(attrs, :violations, []),
        reasons: Map.get(attrs, :reasons, []),
        harness_failure?: outcome == :error,
        metrics: metrics
      },
      evidence: %{final_status: "valid", questions: ["Which days?"]}
    }
  end

  defp runs(outcomes) do
    outcomes
    |> Enum.with_index()
    |> Enum.map(fn {{outcome, attrs}, index} -> run(index, outcome, attrs) end)
  end

  defp all(n, outcome, attrs \\ %{}), do: List.duplicate({outcome, attrs}, n)

  defp build(results), do: Report.build(config(), results, planned_runs: 75)

  test "68 correct runs out of 75 pass" do
    report = build(runs(all(68, :correct) ++ all(7, :incorrect)))

    assert report["summary"]["correct"] == 68
    assert report["summary"]["min_correct"] == 68
    assert report["summary"]["score"] == 0.9067
    assert report["summary"]["verdict"] == "pass"
  end

  test "67 correct runs out of 75 fail" do
    report = build(runs(all(67, :correct) ++ all(8, :incorrect)))

    assert report["summary"]["verdict"] == "fail"
    assert "67 correct runs, 68 required" in report["summary"]["verdict_reasons"]
  end

  test "a single hard-rule violation fails the battery regardless of score" do
    report =
      build(runs(all(74, :correct) ++ [{:hard_violation, %{violations: [:restriction]}}]))

    assert report["summary"]["hard_violations"] == 1
    assert report["summary"]["verdict"] == "fail"

    assert "1 run presented a hard-rule violation as valid" in report["summary"][
             "verdict_reasons"
           ]
  end

  test "runs left unrun by the spend ceiling make the battery incomplete" do
    report = Report.build(config(), runs(all(70, :correct)), planned_runs: 75)

    assert report["summary"]["not_run"] == 5
    assert report["summary"]["verdict"] == "incomplete"
  end

  test "not-run results are listed but never counted, graded or measured" do
    results =
      runs(
        all(3, :correct, %{spend_micros: 40, latency_ms: 200}) ++
          [{:not_run, %{spend_micros: 20, latency_ms: 1, metrics: %{escalation: false}}}]
      )

    report = Report.build(config(), results, planned_runs: 10)
    summary = report["summary"]

    assert summary["runs"] == 3
    assert summary["not_run"] == 7
    assert summary["incorrect"] == 0
    assert summary["score"] == 0.3
    # The cut run's spend was really spent.
    assert summary["spend_micros"] == 140
    assert summary["verdict"] == "incomplete"

    gate = &Enum.find(report["gates"], fn gate -> gate["name"] == &1 end)
    assert gate.("max_cost_micros_per_completed_task")["measured"] == 40.0
    assert gate.("max_latency_ms_p50")["measured"] == 200
    assert gate.("min_escalation_quality")["measured"] == 1.0

    assert [_, _, _, %{"outcome" => "not_run"}] = report["runs"]

    assert Report.render(report, :markdown) =~
             "| 10 | 3 | 3 | 9 | 0 | 0 | 0 | 0 | 7 | 0.3 | 140 |"
  end

  test "a battery that did not run in full is incomplete even with a hard violation" do
    report =
      build(runs(all(69, :correct) ++ [{:hard_violation, %{violations: [:restriction]}}]))

    assert report["summary"]["verdict"] == "incomplete"

    assert report["summary"]["verdict_reasons"] == [
             "5 planned runs did not run (spend ceiling reached)",
             "1 run presented a hard-rule violation as valid"
           ]
  end

  test "pending reviews that could still reach the minimum leave the verdict pending" do
    report = build(runs(all(60, :correct) ++ all(15, :pending_review)))

    assert report["summary"]["verdict"] == "pending_human_review"
  end

  test "enough correct runs pass even with pending reviews" do
    assert build(runs(all(70, :correct) ++ all(5, :pending_review)))["summary"]["verdict"] ==
             "pass"
  end

  test "a gate over its threshold fails the battery" do
    report = build(runs(all(75, :correct, %{latency_ms: 5_000})))

    gate = Enum.find(report["gates"], &(&1["name"] == "max_latency_ms_p95"))

    assert gate == %{
             "name" => "max_latency_ms_p95",
             "threshold" => 2_000,
             "measured" => 5_000,
             "passed" => false
           }

    assert report["summary"]["verdict"] == "fail"
  end

  test "computes every gate from the runs" do
    results =
      runs(
        all(50, :correct, %{spend_micros: 30, metrics: %{questions: 1, provenance: {1, 2}}}) ++
          all(25, :correct, %{metrics: %{escalation: nil, recovery: {0, 0}}})
      )

    gates = Map.new(build(results)["gates"], &{&1["name"], &1["measured"]})

    assert gates["max_cost_micros_per_completed_task"] == 20.0
    assert gates["max_latency_ms_p50"] == 100
    assert gates["max_questions_per_run"] == 0.6667
    assert gates["min_provenance_coverage"] == 0.6
    assert gates["min_escalation_quality"] == 1.0
    assert gates["min_recovery_correctness"] == 1.0
  end

  test "a gate without evidence is not measured and does not pass" do
    report = build(runs(all(75, :correct, %{metrics: %{recovery: {0, 0}}})))

    gate = Enum.find(report["gates"], &(&1["name"] == "min_recovery_correctness"))
    assert gate["measured"] == nil
    assert gate["passed"] == false
    assert "gate min_recovery_correctness not measured" in report["summary"]["verdict_reasons"]
  end

  test "lists harness failures, which reopen the architecture decision" do
    report = build(runs(all(74, :correct) ++ [{:error, %{reasons: ["a turn crashed"]}}]))

    assert [%{"task_id" => _, "run" => _, "reasons" => ["a turn crashed"]}] =
             report["harness_failures"]

    assert report["summary"]["harness_note"] =~ "reopens the architecture decision"
  end

  test "keeps per-run evidence and the configuration" do
    report = build(runs(all(75, :correct)))

    assert length(report["runs"]) == 75

    assert %{"outcome" => "correct", "evidence" => %{"final_status" => "valid"}} =
             hd(report["runs"])

    assert report["config"]["spend_ceiling_micros"] == 1_234
  end

  test "renders JSON" do
    report = build(runs(all(75, :correct)))

    assert {:ok, %{"summary" => %{"verdict" => "pass"}}} =
             report |> Report.render(:json) |> Jason.decode()
  end

  test "renders Markdown with the verdict, gates and every run" do
    report = build(runs(all(74, :correct) ++ [{:hard_violation, %{violations: [:budget]}}]))
    markdown = Report.render(report, :markdown)

    assert markdown =~ "# Planning agent quality battery"
    assert markdown =~ "**Verdict: FAIL**"
    assert markdown =~ "| max_latency_ms_p95 |"
    assert markdown =~ "hard_violation"
    assert markdown =~ "budget"
    assert length(String.split(markdown, "\n| T")) >= 76
  end
end
