defmodule MealPlannerApi.PlanningAgent.Model.Scripted do
  @moduledoc """
  Deterministic, offline model adapter (spec #93, user story 106).

  It replays a script, one step per `respond/2` call, so the whole planning
  loop can be exercised without a provider.

  ## Options

    * `:script` — list of steps. A step is one of:
      * `{:text, text}` — the model answers with assistant text
      * `{:tool_calls, [{name, arguments}]}` — the model calls tools
      * a 1-arity function receiving the request and returning a step
    * `:notify` — pid that receives `{:scripted_model_request, request}` for
      every call, so tests can assert on what the model was sent

  When the script is exhausted `respond/2` returns `{:error, :script_exhausted}`.
  """

  @behaviour MealPlannerApi.PlanningAgent.Model

  @impl true
  def init(opts) do
    {:ok, %{script: Keyword.get(opts, :script, []), notify: Keyword.get(opts, :notify), calls: 0}}
  end

  @impl true
  def respond(%{script: []} = state, request) do
    notify(state, request)
    {:error, :script_exhausted, state}
  end

  def respond(%{script: [step | rest]} = state, request) do
    notify(state, request)
    state = %{state | script: rest, calls: state.calls + 1}
    # Like a dispatched paid call, the consumed step is reported before it
    # resolves, so a step killed at its deadline is not replayed.
    checkpoint(request, state)

    case resolve(step, request) do
      {:text, text} ->
        {:ok, %{text: text, tool_calls: [], usage: usage()}, state}

      {:tool_calls, calls} ->
        tool_calls =
          calls
          |> Enum.with_index(1)
          |> Enum.map(fn {{name, arguments}, index} ->
            %{id: "call_#{state.calls}_#{index}", name: name, arguments: arguments}
          end)

        {:ok, %{text: nil, tool_calls: tool_calls, usage: usage()}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp resolve(step, request) when is_function(step, 1), do: resolve(step.(request), request)
  defp resolve(step, _request), do: step

  defp usage, do: %{input_tokens: 0, output_tokens: 0}

  defp notify(%{notify: pid}, request) when is_pid(pid),
    do: send(pid, {:scripted_model_request, request})

  defp notify(_state, _request), do: :ok

  defp checkpoint(%{checkpoint: checkpoint}, state) when is_function(checkpoint, 1),
    do: checkpoint.(state)

  defp checkpoint(_request, _state), do: :ok
end
