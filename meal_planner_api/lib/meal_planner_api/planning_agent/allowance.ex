defmodule MealPlannerApi.PlanningAgent.Allowance do
  @moduledoc """
  Execution allowance of one Planning Session (spec #93, contract #86
  point 1): agent iterations and consecutive attempts without verifiable
  progress.

    * **Iterations** count model calls (decide, act through tools, evaluate)
      over the whole Planning Session, not per Member message: a new message
      never resets them. Retries of one call are not iterations; they are
      bounded by `MealPlannerApi.PlanningAgent.CallBounds` and the spend caps.
    * **No progress**: an attempt (one iteration with tool calls) makes
      verifiable progress only when at least one tool returned evidence not
      seen before in this session: unchanged retries, rewording that finds
      the same recipes, failed calls or an identical plan are not progress.
      Three consecutive attempts without progress stop execution.

  Counters never reset on their own. `authorize/2` is the only way past a
  reached limit and is called only for the Member's explicit authorization.
  """

  @default_max_no_progress 3

  @enforce_keys [:max_iterations, :iteration_limit]
  defstruct max_iterations: nil,
            iteration_limit: nil,
            iterations: 0,
            max_no_progress: @default_max_no_progress,
            no_progress: 0,
            evidence: MapSet.new()

  @type t :: %__MODULE__{
          max_iterations: pos_integer(),
          iteration_limit: non_neg_integer(),
          iterations: non_neg_integer(),
          max_no_progress: pos_integer(),
          no_progress: non_neg_integer(),
          evidence: MapSet.t()
        }

  @type limit :: String.t()

  @doc "A fresh allowance of `max_iterations` iterations."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(max_iterations, max_no_progress \\ @default_max_no_progress),
    do: %__MODULE__{
      max_iterations: max_iterations,
      iteration_limit: max_iterations,
      max_no_progress: max_no_progress
    }

  @doc "Counts one iteration, or refuses when the iteration limit is reached."
  @spec start_iteration(t()) :: {:ok, t()} | {:limit, limit()}
  def start_iteration(%__MODULE__{} = allowance) do
    if allowance.iterations >= allowance.iteration_limit,
      do: {:limit, "iterations"},
      else: {:ok, %{allowance | iterations: allowance.iterations + 1}}
  end

  @doc """
  Records one attempt given the fingerprints of the evidence its tools
  produced. Reaching the no-progress limit returns `{:limit, "no_progress", allowance}`.
  """
  @spec record_attempt(t(), [term()]) :: {:ok, t()} | {:limit, limit(), t()}
  def record_attempt(%__MODULE__{} = allowance, fingerprints) do
    new_evidence = Enum.reject(fingerprints, &MapSet.member?(allowance.evidence, &1))

    allowance =
      if new_evidence == [] do
        %{allowance | no_progress: allowance.no_progress + 1}
      else
        %{
          allowance
          | no_progress: 0,
            evidence: MapSet.union(allowance.evidence, MapSet.new(new_evidence))
        }
      end

    if allowance.no_progress >= allowance.max_no_progress,
      do: {:limit, "no_progress", allowance},
      else: {:ok, allowance}
  end

  @doc """
  The Member's authorization to continue past `limit`: grants another
  `max_iterations` iterations, or another run of attempts without progress.
  A time limit needs no counter change: the next request has its own deadline.
  """
  @spec authorize(t(), limit()) :: t()
  def authorize(%__MODULE__{} = allowance, "iterations"),
    do: %{allowance | iteration_limit: allowance.iterations + allowance.max_iterations}

  def authorize(%__MODULE__{} = allowance, "no_progress"), do: %{allowance | no_progress: 0}
  def authorize(%__MODULE__{} = allowance, "time"), do: allowance
end
