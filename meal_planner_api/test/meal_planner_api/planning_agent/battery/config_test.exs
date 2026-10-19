defmodule MealPlannerApi.PlanningAgent.Battery.ConfigTest do
  @moduledoc """
  The battery's spend ceiling and #87 deferred criteria are a human decision
  with no defaults (issue #109): a configuration missing any of them is
  refused.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.Battery.Config
  alias MealPlannerApi.PlanningAgent.BatteryFixtures

  defp complete, do: BatteryFixtures.config_map()

  test "accepts a complete configuration" do
    assert {:ok, %Config{} = config} = Config.validate(complete())
    assert config.spend_ceiling_micros == 1_234

    assert config.judges == %{
             abstention_cause: :deterministic,
             relevance: :human,
             variety: :deterministic
           }

    assert config.thresholds.max_questions_per_run == 1.5
    assert config.evidence_format == :markdown
  end

  test "refuses without a spend ceiling" do
    assert {:error, {:unconfigured, ["spend_ceiling_micros: missing"]}} =
             Config.validate(Map.delete(complete(), "spend_ceiling_micros"))
  end

  for bad <- [0, -1, 1.5, "100"] do
    test "refuses a spend ceiling of #{inspect(bad)}" do
      config = Map.put(complete(), "spend_ceiling_micros", unquote(bad))

      assert {:error, {:unconfigured, ["spend_ceiling_micros: must be a positive integer"]}} =
               Config.validate(config)
    end
  end

  test "refuses an empty configuration naming every missing decision" do
    assert {:error, {:unconfigured, problems}} = Config.validate(%{})

    assert problems == [
             "spend_ceiling_micros: missing",
             "judges: missing",
             "thresholds: missing",
             "evidence_format: must be \"json\" or \"markdown\""
           ]
  end

  test "refuses a missing or unknown judge" do
    config =
      put_in(complete(), ["judges"], %{"abstention_cause" => "model", "variety" => "human"})

    assert {:error, {:unconfigured, problems}} = Config.validate(config)

    assert problems == [
             "judges.abstention_cause: must be \"deterministic\" or \"human\"",
             "judges.relevance: must be \"deterministic\" or \"human\""
           ]
  end

  test "refuses every missing or out-of-range threshold" do
    config =
      complete()
      |> pop_in(["thresholds", "max_latency_ms_p95"])
      |> elem(1)
      |> put_in(["thresholds", "min_provenance_coverage"], 1.2)

    assert {:error, {:unconfigured, problems}} = Config.validate(config)

    assert problems == [
             "thresholds.max_latency_ms_p95: must be a positive integer",
             "thresholds.min_provenance_coverage: must be a number from 0 to 1"
           ]
  end

  test "refuses anything that is not an object" do
    assert {:error, {:unconfigured, ["configuration: must be a JSON object"]}} =
             Config.validate([1, 2])
  end

  test "to_data/1 echoes the decisions for the report" do
    {:ok, config} = Config.validate(complete())
    data = Config.to_data(config)

    assert data["spend_ceiling_micros"] == 1_234
    assert data["judges"]["relevance"] == "human"
    assert data["thresholds"]["min_escalation_quality"] == 1
    assert data["evidence_format"] == "markdown"
  end
end
