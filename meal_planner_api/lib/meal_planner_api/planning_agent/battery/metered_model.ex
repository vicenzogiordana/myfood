defmodule MealPlannerApi.PlanningAgent.Battery.MeteredModel do
  @moduledoc """
  Wraps the battery's model adapter (issue #109) to meter the paid spend of
  each run against the battery's spend ceiling. It changes nothing the
  agent sees: every call is the inner adapter's.

  After every call the inner adapter's spend so far (`spend/1`, spent plus
  still reserved micro-USD, so unknown outcomes count as spent) is recorded
  in the `:meter` Agent under the `:run` key. An adapter without `spend/1`
  (the offline scripted model) spends nothing.

  Options: `:inner` (`{module, opts}`), `:meter` (an Agent holding a map)
  and `:run` (the key of this run).
  """

  @behaviour MealPlannerApi.PlanningAgent.Model

  alias MealPlannerApi.PlanningAgent.Model

  @impl true
  def init(opts) do
    {module, inner_opts} = Keyword.fetch!(opts, :inner)

    with {:ok, inner} <- module.init(inner_opts) do
      {:ok, state(module, inner, opts)}
    end
  end

  @impl true
  def respond(%{module: module, inner: inner} = state, request) do
    # The inner adapter checkpoints its own state (a reservation made before
    # a paid call); the session must keep this wrapper's state, metered, so
    # a call killed mid-flight still counts its reservation.
    request =
      case request do
        %{checkpoint: checkpoint} when is_function(checkpoint, 1) ->
          %{request | checkpoint: fn inner -> checkpoint.(meter(%{state | inner: inner})) end}

        request ->
          request
      end

    case module.respond(inner, request) do
      {:ok, response, inner} -> {:ok, response, meter(%{state | inner: inner})}
      {:error, reason, inner} -> {:error, reason, meter(%{state | inner: inner})}
    end
  end

  @impl true
  def recoverable(%{module: module, inner: inner}), do: Model.recoverable(module, inner)

  @impl true
  def recover(opts, recoverable) do
    {module, inner_opts} = Keyword.fetch!(opts, :inner)

    with {:ok, inner} <- Model.recover(module, inner_opts, recoverable) do
      {:ok, state(module, inner, opts)}
    end
  end

  @doc "The spend of `module`'s `state` so far in micro-USD (0 without `spend/1`)."
  @spec spent_micros(module(), term()) :: non_neg_integer()
  def spent_micros(module, state) do
    if Code.ensure_loaded?(module) and function_exported?(module, :spend, 1) do
      spend = module.spend(state)
      Map.get(spend, :spent_micros, 0) + Map.get(spend, :reserved_micros, 0)
    else
      0
    end
  end

  defp state(module, inner, opts),
    do: %{
      module: module,
      inner: inner,
      meter: Keyword.fetch!(opts, :meter),
      run: Keyword.fetch!(opts, :run)
    }

  defp meter(%{meter: meter, run: run, module: module, inner: inner} = state) do
    micros = spent_micros(module, inner)
    Agent.update(meter, &Map.update(&1, run, micros, fn old -> max(old, micros) end))
    state
  end
end
