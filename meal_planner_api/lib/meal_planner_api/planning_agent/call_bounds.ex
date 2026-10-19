defmodule MealPlannerApi.PlanningAgent.CallBounds do
  @moduledoc """
  Per-call deadlines and retry budgets of the planning agent (spec #93,
  contract #86 point 2).

  Every model, solver and read-tool call of a turn runs through `run/4`:

    * each attempt has its own deadline (model 60 s, solver 120 s, read tools
      30 s), shortened by what remains of the turn's global deadline; an
      attempt that does not answer in time is killed and reported as
      `:timeout`
    * a transient failure is retried with increasing backoff, up to the
      kind's budget (model 5 retries, solver none, read tools 2)
    * a retry never starts after the global deadline, nor while the Member
      is absent, nor for an error that is not transient (permission,
      configuration, invalid data, conflict or any unknown reason)

  Attempts run in their own process so a deadline can stop them. The attempt
  function receives a call map with `:timeout_ms` (the attempt's effective
  deadline) and `:report`, a callback for intermediate state: a paid model
  adapter reports its reserved spend there, and when the attempt is killed
  the latest reported state is kept, so a timed-out call still counts.
  """

  @type kind :: :model | :solver | :read
  @type policy :: %{
          timeout_ms: pos_integer(),
          retries: non_neg_integer(),
          backoff_ms: non_neg_integer()
        }
  @type t :: %{
          policies: %{kind() => policy()},
          deadline_at: integer(),
          present?: (-> boolean()),
          on_retry: (kind(), pos_integer(), term() -> any())
        }
  @type call :: %{timeout_ms: pos_integer(), report: (term() -> any())}
  @type result :: {:ok, term(), term()} | {:error, term(), term()}

  @default_policies %{
    model: %{timeout_ms: 60_000, retries: 5, backoff_ms: 500},
    solver: %{timeout_ms: 120_000, retries: 0, backoff_ms: 0},
    read: %{timeout_ms: 30_000, retries: 2, backoff_ms: 250}
  }

  # Without a global deadline only the per-call deadline applies.
  @unbounded_ms 1_000_000_000

  # Only these reasons are transient. Anything else, including reasons this
  # module does not know, is never retried automatically. An invalid provider
  # response (incomplete, or neither text nor tool calls) is not transient: it
  # was already billed, and resending the same request would be billed again
  # for the same answer. `:provider_busy` (the global provider concurrency
  # cap was full) is refused before any spend is reserved, so a retry costs
  # nothing.
  @transient %{
    model: [:timeout, :provider_unavailable, :provider_timeout, :provider_busy],
    solver: [],
    read: [:timeout, :search_failed, :scraper_unreachable]
  }

  @doc "The default policies, with `overrides` merged per kind."
  @spec policies(map()) :: %{kind() => policy()}
  def policies(overrides \\ %{}) do
    Map.new(@default_policies, fn {kind, policy} ->
      {kind, Map.merge(policy, Map.get(overrides, kind, %{}))}
    end)
  end

  @doc """
  Builds the bounds of one turn.

  Options: `:policies` (overrides merged into the defaults), `:deadline_at`
  (monotonic milliseconds; default: no global deadline), `:present?` and
  `:on_retry` callbacks.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %{
      policies: policies(Keyword.get(opts, :policies, %{})),
      deadline_at: Keyword.get(opts, :deadline_at),
      present?: Keyword.get(opts, :present?, fn -> true end),
      on_retry: Keyword.get(opts, :on_retry, fn _kind, _attempt, _reason -> :ok end)
    }
  end

  @doc "Whether `reason` is a transient failure for `kind`."
  @spec transient?(kind(), term()) :: boolean()
  def transient?(kind, reason), do: reason in Map.fetch!(@transient, kind)

  @doc """
  Runs `fun.(state, call)` within the bounds of `kind`. `fun` returns
  `{:ok, value, state}` or `{:error, reason, state}`; the state of a failed
  attempt is the input of the next one.
  """
  @spec run(t() | nil, kind(), term(), (term(), call() -> result())) :: result()
  def run(nil, kind, state, fun), do: run(new(), kind, state, fun)

  def run(bounds, kind, state, fun) do
    policy = Map.fetch!(bounds.policies, kind)
    attempt(bounds, kind, policy, state, fun, 1)
  end

  defp attempt(bounds, kind, policy, state, fun, number) do
    case remaining(bounds) do
      remaining when remaining <= 0 ->
        {:error, :deadline_exceeded, state}

      remaining ->
        timeout_ms = min(policy.timeout_ms, remaining)

        case run_attempt(state, fun, timeout_ms) do
          {:ok, _value, _state} = ok ->
            ok

          # The attempt was cut by the global deadline, not by its own.
          {:error, :timeout, state} when timeout_ms == remaining ->
            {:error, :deadline_exceeded, state}

          {:error, :provider_timeout, state} = error when timeout_ms == remaining ->
            if deadline_used?(bounds, timeout_ms),
              do: {:error, :deadline_exceeded, state},
              else: retry_or_fail(bounds, kind, policy, fun, number, error)

          {:error, _reason, _state} = error ->
            retry_or_fail(bounds, kind, policy, fun, number, error)
        end
    end
  end

  # A paid model adapter ends its HTTP call within the last fifth (at most
  # 1 s) of the attempt deadline, so the call settles before the attempt is
  # killed. When the global deadline bounded that attempt, its provider
  # timeout is the global deadline arriving: the time left is that margin,
  # too short for another paid call.
  defp deadline_used?(bounds, timeout_ms),
    do: remaining(bounds) <= min(1_000, div(timeout_ms, 5))

  defp retry_or_fail(bounds, kind, policy, fun, number, {:error, reason, state} = error) do
    delay = backoff(policy, number)

    if retry?(bounds, kind, policy, reason, number, delay) do
      bounds.on_retry.(kind, number + 1, reason)
      Process.sleep(delay)
      attempt(bounds, kind, policy, state, fun, number + 1)
    else
      error
    end
  end

  defp retry?(bounds, kind, policy, reason, number, delay) do
    number <= policy.retries and transient?(kind, reason) and
      remaining(bounds) > delay and bounds.present?.()
  end

  defp backoff(policy, number), do: policy.backoff_ms * Integer.pow(2, number - 1)

  defp remaining(%{deadline_at: nil}), do: @unbounded_ms
  defp remaining(%{deadline_at: at}), do: at - System.monotonic_time(:millisecond)

  defp run_attempt(state, fun, timeout_ms) do
    tag = make_ref()
    caller = self()
    report = fn reported -> send(caller, {__MODULE__, tag, reported}) end
    task = Task.async(fn -> fun.(state, %{timeout_ms: timeout_ms, report: report}) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        _ = latest_report(tag, state)
        result

      {:exit, reason} ->
        exit(reason)

      nil ->
        {:error, :timeout, latest_report(tag, state)}
    end
  end

  defp latest_report(tag, state) do
    receive do
      {__MODULE__, ^tag, reported} -> latest_report(tag, reported)
    after
      0 -> state
    end
  end
end
