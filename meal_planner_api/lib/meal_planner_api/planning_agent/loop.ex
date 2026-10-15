defmodule MealPlannerApi.PlanningAgent.Loop do
  @moduledoc """
  One agent turn: model call, tool calls, model call ... until the model
  answers with text, asks the human, fails, or reaches a limit of the
  session's `MealPlannerApi.PlanningAgent.Allowance` (iterations or
  attempts without verifiable progress).

  Runs inside a task owned by `MealPlannerApi.PlanningAgent.Session`, which
  enforces the global deadline by killing the task and emits the run's
  terminal events from the returned outcome. Progress is reported through
  the `emit` callback; tool output never reaches the instructions.

  The optional `checkpoint` callback receives every model state the turn
  produces (including the adapter's mid-call reservations), and the optional
  `report_allowance` callback every allowance change, so the owner keeps
  paid usage and counted iterations even when it kills the turn.
  """

  alias MealPlannerApi.PlanningAgent.{Allowance, CallBounds, Tools}

  @type turn :: %{
          required(:model) => module(),
          required(:model_state) => term(),
          required(:instructions) => String.t(),
          required(:messages) => [map()],
          required(:tool_context) => Tools.context(),
          required(:allowance) => Allowance.t(),
          required(:emit) => (map() -> any()),
          optional(:checkpoint) => (term() -> any()),
          optional(:report_allowance) => (Allowance.t() -> any()),
          optional(:bounds) => CallBounds.t()
        }

  @type outcome :: :completed | {:limit_reached, String.t()} | {:failed, term()}

  @doc "Runs a turn and returns its outcome with the updated conversation state."
  @spec run(turn()) :: %{
          outcome: outcome(),
          model_state: term(),
          messages: [map()],
          workspace: map(),
          allowance: Allowance.t()
        }
  def run(turn), do: iterate(turn)

  defp iterate(turn) do
    case Allowance.start_iteration(turn.allowance) do
      {:ok, allowance} ->
        turn |> put_allowance(allowance) |> call_model()

      {:limit, limit} ->
        finish(turn, {:limit_reached, limit})
    end
  end

  defp call_model(turn) do
    turn.emit.(%{"type" => "progress", "step" => "thinking"})

    checkpoint = Map.get(turn, :checkpoint, fn _model_state -> :ok end)

    request = %{
      instructions: turn.instructions,
      messages: turn.messages,
      tools: Tools.definitions(),
      checkpoint: checkpoint
    }

    response =
      CallBounds.run(Map.get(turn, :bounds), :model, turn.model_state, fn model_state, call ->
        # Reported states reach the call bounds too, so a killed attempt
        # keeps its reserved spend for the next attempt.
        report = fn reported ->
          call.report.(reported)
          checkpoint.(reported)
        end

        turn.model.respond(model_state, %{request | checkpoint: report})
      end)

    {_status, _result, model_state} = response
    checkpoint.(model_state)
    turn = %{turn | model_state: model_state}

    case response do
      {:ok, %{tool_calls: [_ | _] = calls}, _model_state} ->
        case run_tools(turn, calls) do
          {:continue, turn, fingerprints} -> after_attempt(turn, fingerprints)
          {:end_turn, turn, _fingerprints} -> finish(turn, :completed)
        end

      {:ok, %{text: text}, _model_state} ->
        text = text || ""
        turn.emit.(%{"type" => "assistant_message", "text" => text})
        finish(append(turn, %{role: :assistant, content: text}), :completed)

      {:error, :deadline_exceeded, _model_state} ->
        finish(turn, {:limit_reached, "time"})

      {:error, :timeout, _model_state} ->
        finish(turn, {:failed, :provider_timeout})

      {:error, reason, _model_state} ->
        finish(turn, {:failed, reason})
    end
  end

  defp after_attempt(turn, fingerprints) do
    case Allowance.record_attempt(turn.allowance, fingerprints) do
      {:ok, allowance} ->
        turn |> put_allowance(allowance) |> iterate()

      {:limit, limit, allowance} ->
        turn |> put_allowance(allowance) |> finish({:limit_reached, limit})
    end
  end

  defp run_tools(turn, calls) do
    turn =
      Enum.reduce(calls, turn, fn call, acc ->
        append(acc, %{role: :tool_call, id: call.id, name: call.name, arguments: call.arguments})
      end)

    Enum.reduce(calls, {:continue, turn, []}, fn call, {control, acc, fingerprints} ->
      arguments = if is_map(call.arguments), do: call.arguments, else: %{}
      {content, workspace, call_control} = Tools.execute(call.name, arguments, acc.tool_context)

      # Progress only: the tool's name and outcome kind, never its output.
      acc.emit.(%{
        "type" => "progress",
        "step" => "tool_finished",
        "tool" => tool_label(call.name),
        "outcome" => content["outcome"]
      })

      acc =
        acc
        |> Map.update!(:tool_context, &%{&1 | workspace: workspace})
        |> append(%{role: :tool_result, id: call.id, name: call.name, content: content})

      {merge_control(control, call_control), acc, fingerprint(call.name, content, fingerprints)}
    end)
  end

  # Verifiable progress is evidence: a complete or partial tool result. Its
  # identity ignores generated identifiers, so presenting the same plan twice
  # is not new evidence.
  defp fingerprint(name, %{"outcome" => outcome} = content, fingerprints)
       when outcome in ["complete", "partial"],
       do: [:erlang.phash2({name, Map.delete(content, "proposal_id")}) | fingerprints]

  defp fingerprint(_name, _content, fingerprints), do: fingerprints

  # Tool names come from the model: only catalog names are streamed.
  defp tool_label(name) do
    if Enum.any?(Tools.definitions(), &(&1.name == name)), do: name, else: "unknown"
  end

  defp merge_control(:end_turn, _), do: :end_turn
  defp merge_control(_, control), do: control

  defp append(turn, message), do: %{turn | messages: turn.messages ++ [message]}

  defp put_allowance(turn, allowance) do
    if report = Map.get(turn, :report_allowance), do: report.(allowance)
    %{turn | allowance: allowance}
  end

  defp finish(turn, outcome) do
    %{
      outcome: outcome,
      model_state: turn.model_state,
      messages: turn.messages,
      workspace: turn.tool_context.workspace,
      allowance: turn.allowance
    }
  end
end
