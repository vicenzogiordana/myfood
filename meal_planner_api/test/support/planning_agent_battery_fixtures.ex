defmodule MealPlannerApi.PlanningAgent.BatteryFixtures do
  @moduledoc """
  Fictitious quality battery configurations for tests (issue #109). The
  values are chosen for the tests only; they are not a recommendation for
  the human decision the real configuration needs.
  """

  @doc "A complete battery configuration, as decoded from JSON."
  def config_map do
    %{
      "spend_ceiling_micros" => 1_234,
      "judges" => %{
        "abstention_cause" => "deterministic",
        "relevance" => "human",
        "variety" => "deterministic"
      },
      "thresholds" => %{
        "max_cost_micros_per_completed_task" => 10,
        "max_latency_ms_p50" => 1_000,
        "max_latency_ms_p95" => 2_000,
        "max_questions_per_run" => 1.5,
        "min_provenance_coverage" => 0.5,
        "min_escalation_quality" => 1,
        "min_recovery_correctness" => 0
      },
      "evidence_format" => "markdown"
    }
  end
end
