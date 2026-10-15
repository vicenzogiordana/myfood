defmodule MealPlannerApi.PlanningAgent.Loop do
  @moduledoc """
  One agent turn: model call, tool calls, model call ... until the model
  answers with text, asks the human, fails, or reaches the iteration limit.

  Runs inside a task owned by `MealPlannerApi.PlanningAgent.Session`, which
  enforces the global deadline by killing the task. Progress is reported
  through the `emit` callback; tool output never reaches the instructions.
  """

  alias MealPlannerApi.PlanningAgent.Tools

  @type turn :: %{
          model: module(),
          model_state: term(),
          instructions: String.t(),
          messages: [map()],
          tool_context: Tools.context(),
          max_iterations: pos_integer(),
          emit: (map() -> any())
        }

  @type outcome :: :completed | {:limit_reached, String.t()} | {:failed, term()}

  @doc "Runs a turn and returns its outcome with the updated conversation state."
  @spec run(turn()) :: %{
          outcome: outcome(),
          model_state: term(),
          messages: [map()],
          workspace: map()
        }
  def run(turn), do: iterate(turn, 1)

  defp iterate(turn, iteration) when iteration > turn.max_iterations do
    turn.emit.(%{"type" => "limit_reached", "limit" => "iterations"})
    finish(turn, {:limit_reached, "iterations"})
  end

  defp iterate(turn, iteration) do
    turn.emit.(%{"type" => "progress", "step" => "thinking"})

    request = %{
      instructions: turn.instructions,
      messages: turn.messages,
      tools: Tools.definitions()
    }

    case turn.model.respond(turn.model_state, request) do
      {:ok, %{tool_calls: [_ | _] = calls}, model_state} ->
        turn = %{turn | model_state: model_state}

        case run_tools(turn, calls) do
          {:continue, turn} -> iterate(turn, iteration + 1)
          {:end_turn, turn} -> finish(turn, :completed)
        end

      {:ok, %{text: text}, model_state} ->
        turn = %{turn | model_state: model_state}
        text = text || ""
        turn.emit.(%{"type" => "assistant_message", "text" => text})
        finish(append(turn, %{role: :assistant, content: text}), :completed)

      {:error, reason, model_state} ->
        turn.emit.(%{"type" => "agent_unavailable", "reason" => reason_string(reason)})
        finish(%{turn | model_state: model_state}, {:failed, reason})
    end
  end

  defp run_tools(turn, calls) do
    turn =
      Enum.reduce(calls, turn, fn call, acc ->
        append(acc, %{role: :tool_call, id: call.id, name: call.name, arguments: call.arguments})
      end)

    Enum.reduce(calls, {:continue, turn}, fn call, {control, acc} ->
      arguments = if is_map(call.arguments), do: call.arguments, else: %{}
      {content, workspace, call_control} = Tools.execute(call.name, arguments, acc.tool_context)

      acc =
        acc
        |> Map.update!(:tool_context, &%{&1 | workspace: workspace})
        |> append(%{role: :tool_result, id: call.id, name: call.name, content: content})

      {merge_control(control, call_control), acc}
    end)
  end

  defp merge_control(:end_turn, _), do: :end_turn
  defp merge_control(_, control), do: control

  defp append(turn, message), do: %{turn | messages: turn.messages ++ [message]}

  defp finish(turn, outcome) do
    %{
      outcome: outcome,
      model_state: turn.model_state,
      messages: turn.messages,
      workspace: turn.tool_context.workspace
    }
  end

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason), do: "provider_error"
end
