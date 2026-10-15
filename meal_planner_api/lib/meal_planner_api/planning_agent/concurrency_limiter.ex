defmodule MealPlannerApi.PlanningAgent.ConcurrencyLimiter do
  @moduledoc """
  Global concurrency slots of the planning agent (spec #93, issue #118):
  model-provider calls and optimizer subprocesses of every Planning Session
  together never exceed their configured caps.

  `run/4` takes one slot of a key, runs the function in the calling process
  and gives the slot back. A call over the cap is refused at once with
  `{:error, :at_capacity}` and never queued, so a caller decides whether to
  retry. A slot is tied to its holder process: it comes back when the
  function returns or raises, and also when the holder is killed (for
  example an attempt halted with `:brutal_kill` by Stop or a deadline).

  The caps are a human decision; a missing or invalid one refuses with
  `{:error, :unconfigured}`.
  """

  use GenServer

  @type key :: atom()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Runs `fun` holding one slot of `key`, at most `limit` at a time.
  Returns `{:ok, fun_result}`, `{:error, :at_capacity}` without running it,
  or `{:error, :unconfigured}` when `limit` is not a positive integer.
  """
  @spec run(GenServer.server(), key(), term(), (-> result)) ::
          {:ok, result} | {:error, :at_capacity | :unconfigured}
        when result: term()
  def run(limiter \\ __MODULE__, key, limit, fun)

  def run(limiter, key, limit, fun) when is_integer(limit) and limit > 0 do
    case GenServer.call(limiter, {:acquire, key, limit, self()}) do
      {:ok, slot} ->
        try do
          {:ok, fun.()}
        after
          GenServer.call(limiter, {:release, slot})
        end

      {:error, :at_capacity} = refused ->
        refused
    end
  end

  def run(_limiter, _key, _limit, _fun), do: {:error, :unconfigured}

  @doc "Slots of `key` currently held."
  @spec in_use(GenServer.server(), key()) :: non_neg_integer()
  def in_use(limiter \\ __MODULE__, key), do: GenServer.call(limiter, {:in_use, key})

  @impl true
  def init(:ok), do: {:ok, %{slots: %{}, counts: %{}}}

  @impl true
  def handle_call({:acquire, key, limit, holder}, _from, state) do
    if Map.get(state.counts, key, 0) >= limit do
      {:reply, {:error, :at_capacity}, state}
    else
      slot = Process.monitor(holder)

      state = %{
        state
        | slots: Map.put(state.slots, slot, key),
          counts: Map.update(state.counts, key, 1, &(&1 + 1))
      }

      {:reply, {:ok, slot}, state}
    end
  end

  def handle_call({:in_use, key}, _from, state),
    do: {:reply, Map.get(state.counts, key, 0), state}

  def handle_call({:release, slot}, _from, state) do
    Process.demonitor(slot, [:flush])
    {:reply, :ok, free(state, slot)}
  end

  @impl true
  def handle_info({:DOWN, slot, :process, _holder, _reason}, state),
    do: {:noreply, free(state, slot)}

  defp free(state, slot) do
    case Map.pop(state.slots, slot) do
      {nil, _slots} ->
        state

      {key, slots} ->
        %{state | slots: slots, counts: Map.update!(state.counts, key, &(&1 - 1))}
    end
  end
end
