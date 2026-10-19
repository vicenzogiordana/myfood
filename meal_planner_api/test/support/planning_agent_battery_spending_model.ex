defmodule MealPlannerApi.PlanningAgent.BatterySpendingModel do
  @moduledoc """
  Model adapter fake for the battery's spend ceiling tests (issue #109): it
  delegates to an inner adapter (the scripted model) and reports a fixed,
  fictitious spend per call through `spend/1`, as the paid adapter does. A
  call that would exceed its per-session `:spend_cap_micros` is refused.

  Options: `:inner`, `:micros_per_call`, `:spend_cap_micros` and `:notify`,
  which receives `{:spending_model_init, spend_cap_micros}` on every init.
  """

  @behaviour MealPlannerApi.PlanningAgent.Model

  @impl true
  def init(opts) do
    {module, inner_opts} = Keyword.fetch!(opts, :inner)
    cap = Keyword.fetch!(opts, :spend_cap_micros)
    if pid = opts[:notify], do: send(pid, {:spending_model_init, cap})

    with {:ok, inner} <- module.init(inner_opts) do
      {:ok,
       %{
         module: module,
         inner: inner,
         cap: cap,
         per_call: Keyword.fetch!(opts, :micros_per_call),
         spent: 0
       }}
    end
  end

  @impl true
  def respond(%{spent: spent, per_call: per_call, cap: cap} = state, _request)
      when spent + per_call > cap,
      do: {:error, :spend_cap_reached, state}

  def respond(%{module: module, inner: inner} = state, request) do
    state = %{state | spent: state.spent + state.per_call}

    case module.respond(inner, Map.delete(request, :checkpoint)) do
      {:ok, response, inner} -> {:ok, response, %{state | inner: inner}}
      {:error, reason, inner} -> {:error, reason, %{state | inner: inner}}
    end
  end

  @doc "Spend so far, shaped like the paid adapter's."
  def spend(%{spent: spent}), do: %{spent_micros: spent, reserved_micros: 0}
end
