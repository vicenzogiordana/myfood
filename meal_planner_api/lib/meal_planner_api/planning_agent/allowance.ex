defmodule MealPlannerApi.PlanningAgent.Allowance do
  @moduledoc """
  Execution allowance of one Planning Session (spec #93, contract #86
  point 1, issue #154): agent iterations and consecutive attempts without
  verifiable progress.

    * **Iterations** count model calls (decide, act through tools,
      evaluate). Each Member message gets `max_iterations` of them (default
      15): reaching it stops the run until the Member authorizes another
      `max_iterations`. The whole Planning Session never makes more than
      `max_session_iterations` (default 60): that ceiling is never extended,
      so reaching it exhausts the session (`{:exhausted, "session_iterations"}`).
      Retries of one call are not iterations; they are bounded by
      `MealPlannerApi.PlanningAgent.CallBounds` and the spend caps. A call
      refused before it reached the provider is refunded
      (`refund_iteration/1`) and never counts.
    * **No progress**: an attempt (one iteration with tool calls) makes
      verifiable progress only when at least one tool returned evidence not
      seen before in this session: unchanged retries, rewording that finds
      the same recipes, failed calls or an identical plan are not progress.
      Three consecutive attempts without progress stop execution.

  `start_message/1` is the only reset, of the message's iterations only.
  `authorize/2` is the only way past a reached limit and is called only for
  the Member's explicit authorization.
  """

  @default_max_iterations 15
  @default_max_session_iterations 60
  @default_max_no_progress 3

  @enforce_keys [:max_iterations, :iteration_limit]
  defstruct max_iterations: nil,
            iteration_limit: nil,
            iterations: 0,
            message_iterations: 0,
            max_session_iterations: @default_max_session_iterations,
            max_no_progress: @default_max_no_progress,
            no_progress: 0,
            evidence: MapSet.new()

  @type t :: %__MODULE__{
          max_iterations: pos_integer(),
          iteration_limit: non_neg_integer(),
          iterations: non_neg_integer(),
          message_iterations: non_neg_integer(),
          max_session_iterations: pos_integer(),
          max_no_progress: pos_integer(),
          no_progress: non_neg_integer(),
          evidence: MapSet.t()
        }

  @type limit :: String.t()

  @doc """
  A fresh allowance of `max_iterations` iterations per Member message.

  ## Options

    * `:max_session_iterations` — the Planning Session's ceiling (default 60)
    * `:max_no_progress` — attempts without progress in a row (default 3)
  """
  @spec new(pos_integer(), keyword()) :: t()
  def new(max_iterations \\ @default_max_iterations, opts \\ []),
    do: %__MODULE__{
      max_iterations: max_iterations,
      iteration_limit: max_iterations,
      max_session_iterations:
        Keyword.get(opts, :max_session_iterations, @default_max_session_iterations),
      max_no_progress: Keyword.get(opts, :max_no_progress, @default_max_no_progress)
    }

  @doc """
  A recovered allowance: the saved counters over `fresh`, so a snapshot
  stored before a counter existed gains it with its default. The limits
  are the current ones of `fresh`.
  """
  @spec restore(map(), t()) :: t()
  def restore(saved, %__MODULE__{} = fresh) do
    counters = Map.take(saved, [:iterations, :no_progress, :evidence])
    struct(fresh, counters)
  end

  @doc "A new Member message: its own `max_iterations` iterations start."
  @spec start_message(t()) :: t()
  def start_message(%__MODULE__{} = allowance),
    do: %{allowance | message_iterations: 0, iteration_limit: allowance.max_iterations}

  @doc """
  Counts one iteration. Refuses with `{:limit, "iterations"}` when the
  message's limit is reached, and with `{:exhausted, "session_iterations"}`
  when the Planning Session's ceiling is.
  """
  @spec start_iteration(t()) :: {:ok, t()} | {:limit, limit()} | {:exhausted, limit()}
  def start_iteration(%__MODULE__{} = allowance) do
    cond do
      allowance.iterations >= allowance.max_session_iterations ->
        {:exhausted, "session_iterations"}

      allowance.message_iterations >= allowance.iteration_limit ->
        {:limit, "iterations"}

      true ->
        {:ok,
         %{
           allowance
           | iterations: allowance.iterations + 1,
             message_iterations: allowance.message_iterations + 1
         }}
    end
  end

  @doc "Takes back the last iteration: its call was refused before reaching the provider."
  @spec refund_iteration(t()) :: t()
  def refund_iteration(%__MODULE__{} = allowance),
    do: %{
      allowance
      | iterations: max(allowance.iterations - 1, 0),
        message_iterations: max(allowance.message_iterations - 1, 0)
    }

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
  `max_iterations` iterations of the current message (never past the
  session ceiling), or another run of attempts without progress. A time
  limit needs no counter change: the next request has its own deadline.
  """
  @spec authorize(t(), limit()) :: t()
  def authorize(%__MODULE__{} = allowance, "iterations"),
    do: %{allowance | iteration_limit: allowance.message_iterations + allowance.max_iterations}

  def authorize(%__MODULE__{} = allowance, "no_progress"), do: %{allowance | no_progress: 0}
  def authorize(%__MODULE__{} = allowance, "time"), do: allowance
end
