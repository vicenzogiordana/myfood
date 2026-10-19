defmodule MealPlannerApi.PlanningAgent.Battery.Config do
  @moduledoc """
  The human-supplied configuration of the quality battery (issue #109,
  agreed in #87): the battery's spend ceiling and the criteria #87 deferred
  until after the hands-on prototype. None of them has a default value: they
  are a human decision, and `validate/1` refuses a configuration that leaves
  any of them out, so the battery never starts without them.

  The configuration is a JSON object (string keys):

      {
        "spend_ceiling_micros": <positive integer, micro-USD for the whole battery>,
        "judges": {
          "abstention_cause": "deterministic" | "human",
          "relevance": "deterministic" | "human",
          "variety": "deterministic" | "human"
        },
        "thresholds": {
          "max_cost_micros_per_completed_task": <non-negative integer>,
          "max_latency_ms_p50": <positive integer>,
          "max_latency_ms_p95": <positive integer>,
          "max_questions_per_run": <non-negative number>,
          "min_provenance_coverage": <number from 0 to 1>,
          "min_escalation_quality": <number from 0 to 1>,
          "min_recovery_correctness": <number from 0 to 1>
        },
        "evidence_format": "json" | "markdown"
      }

  What each criterion means (see `MealPlannerApi.PlanningAgent.Battery.Report`):

    * `judges` — who judges each criterion #87 left open. `deterministic`
      uses the task's code-owned checks (cause markers of an abstention, the
      task's relevance checks, the independent variety check); `human` leaves
      the run pending human review with its evidence. Hard rules are always
      judged by code.
    * `max_cost_micros_per_completed_task` — paid spend of the whole battery
      divided by its correct runs
    * `max_latency_ms_p50` / `max_latency_ms_p95` — wall time per run
    * `max_questions_per_run` — extra user effort: mean questions the agent
      asked per run
    * `min_provenance_coverage` — share of Purchase lines in the final
      Proposals carrying full price provenance (product, presentation,
      supermarket, currency, observation time)
    * `min_escalation_quality` — share of runs on unsolvable tasks that
      ended telling the Member the real cause
    * `min_recovery_correctness` — share of the battery's recovery checks
      (stale and duplicate confirmations) that held
    * `evidence_format` — the format the report is written in
  """

  @enforce_keys [:spend_ceiling_micros, :judges, :thresholds, :evidence_format]
  defstruct @enforce_keys

  @type judge :: :deterministic | :human
  @type t :: %__MODULE__{
          spend_ceiling_micros: pos_integer(),
          judges: %{abstention_cause: judge(), relevance: judge(), variety: judge()},
          thresholds: %{atom() => number()},
          evidence_format: :json | :markdown
        }

  @judged ~w(abstention_cause relevance variety)
  @judges %{"deterministic" => :deterministic, "human" => :human}
  @formats %{"json" => :json, "markdown" => :markdown}

  # {key, validator, expectation shown when invalid}
  @thresholds [
    {"max_cost_micros_per_completed_task", :non_neg_integer, "a non-negative integer"},
    {"max_latency_ms_p50", :pos_integer, "a positive integer"},
    {"max_latency_ms_p95", :pos_integer, "a positive integer"},
    {"max_questions_per_run", :non_neg_number, "a non-negative number"},
    {"min_provenance_coverage", :ratio, "a number from 0 to 1"},
    {"min_escalation_quality", :ratio, "a number from 0 to 1"},
    {"min_recovery_correctness", :ratio, "a number from 0 to 1"}
  ]

  @doc "The threshold keys, in report order."
  @spec threshold_keys() :: [atom()]
  def threshold_keys, do: Enum.map(@thresholds, fn {key, _, _} -> String.to_atom(key) end)

  @doc """
  Validates a decoded configuration. Every problem is reported at once as
  `{:error, {:unconfigured, problems}}`, each problem naming its key.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, {:unconfigured, [String.t()]}}
  def validate(config) when is_map(config) do
    {ceiling, p1} = spend_ceiling(Map.get(config, "spend_ceiling_micros"))
    {judges, p2} = judges(Map.get(config, "judges"))
    {thresholds, p3} = thresholds(Map.get(config, "thresholds"))
    {format, p4} = evidence_format(Map.get(config, "evidence_format"))

    case p1 ++ p2 ++ p3 ++ p4 do
      [] ->
        {:ok,
         %__MODULE__{
           spend_ceiling_micros: ceiling,
           judges: judges,
           thresholds: thresholds,
           evidence_format: format
         }}

      problems ->
        {:error, {:unconfigured, problems}}
    end
  end

  def validate(_config), do: {:error, {:unconfigured, ["configuration: must be a JSON object"]}}

  @doc "The configuration as shown in the report (it holds no secrets)."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = config) do
    %{
      "spend_ceiling_micros" => config.spend_ceiling_micros,
      "judges" => Map.new(config.judges, fn {k, v} -> {Atom.to_string(k), Atom.to_string(v)} end),
      "thresholds" => Map.new(config.thresholds, fn {k, v} -> {Atom.to_string(k), v} end),
      "evidence_format" => Atom.to_string(config.evidence_format)
    }
  end

  defp spend_ceiling(nil), do: {nil, ["spend_ceiling_micros: missing"]}
  defp spend_ceiling(value) when is_integer(value) and value > 0, do: {value, []}
  defp spend_ceiling(_), do: {nil, ["spend_ceiling_micros: must be a positive integer"]}

  defp judges(judges) when is_map(judges) do
    Enum.reduce(@judged, {%{}, []}, fn key, {acc, problems} ->
      case Map.fetch(@judges, Map.get(judges, key)) do
        {:ok, judge} ->
          {Map.put(acc, String.to_atom(key), judge), problems}

        :error ->
          {acc, problems ++ ["judges.#{key}: must be \"deterministic\" or \"human\""]}
      end
    end)
  end

  defp judges(_), do: {nil, ["judges: missing"]}

  defp thresholds(thresholds) when is_map(thresholds) do
    Enum.reduce(@thresholds, {%{}, []}, fn {key, kind, expected}, {acc, problems} ->
      value = Map.get(thresholds, key)

      if valid?(kind, value),
        do: {Map.put(acc, String.to_atom(key), value), problems},
        else: {acc, problems ++ ["thresholds.#{key}: must be #{expected}"]}
    end)
  end

  defp thresholds(_), do: {nil, ["thresholds: missing"]}

  defp evidence_format(value) do
    case Map.fetch(@formats, value) do
      {:ok, format} -> {format, []}
      :error -> {nil, ["evidence_format: must be \"json\" or \"markdown\""]}
    end
  end

  defp valid?(:pos_integer, v), do: is_integer(v) and v > 0
  defp valid?(:non_neg_integer, v), do: is_integer(v) and v >= 0
  defp valid?(:non_neg_number, v), do: is_number(v) and v >= 0
  defp valid?(:ratio, v), do: is_number(v) and v >= 0 and v <= 1
end
