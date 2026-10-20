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
  paid usage and counted iterations even when it kills the turn. The
  optional `on_workspace` callback receives the Workspace after every tool
  call, so a Stop keeps what deterministic tools already produced
  (including a presented Proposal). The optional `present?` callback is
  asked before every model call: while the Member is absent no new call
  starts and the turn ends `{:interrupted, :member_absent}`.
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
          optional(:bounds) => CallBounds.t(),
          optional(:on_workspace) => (map() -> any()),
          optional(:present?) => (-> boolean())
        }

  @type outcome ::
          :completed
          | {:limit_reached, String.t()}
          | {:failed, term()}
          | {:interrupted, :member_absent}
          | {:exhausted, String.t()}

  @doc "Runs a turn and returns its outcome with the updated conversation state."
  @spec run(turn()) :: %{
          outcome: outcome(),
          model_state: term(),
          messages: [map()],
          workspace: map(),
          allowance: Allowance.t()
        }
  def run(turn), do: iterate(turn)

  # No new model call starts while the Member is absent; the turn ends
  # without counting an iteration.
  defp iterate(turn) do
    if Map.get(turn, :present?, fn -> true end).() do
      case Allowance.start_iteration(turn.allowance) do
        {:ok, allowance} ->
          turn |> put_allowance(allowance) |> call_model()

        {:limit, limit} ->
          finish(turn, {:limit_reached, limit})

        {:exhausted, limit} ->
          finish(turn, {:exhausted, limit})
      end
    else
      finish(turn, {:interrupted, :member_absent})
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

        # The attempt deadline lets the adapter end its HTTP call first.
        request = Map.put(%{request | checkpoint: report}, :timeout_ms, call.timeout_ms)
        turn.model.respond(model_state, request)
      end)

    {_status, _result, model_state} = response
    checkpoint.(model_state)
    turn = %{turn | model_state: model_state} |> refund_refused(response)

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

      # The Planning Session's spend caps are never extended (issue #154).
      {:error, :spend_cap_reached, _model_state} ->
        finish(turn, {:exhausted, "spend_cap"})

      {:error, :token_cap_reached, _model_state} ->
        finish(turn, {:exhausted, "token_cap"})

      {:error, reason, _model_state} ->
        finish(turn, {:failed, reason})
    end
  end

  # A call refused before it reached the provider (no spend, no provider
  # work) is not an iteration (issue #154).
  @refused_before_provider [
    :spend_cap_reached,
    :token_cap_reached,
    :provider_busy,
    :spend_caps_unconfigured
  ]

  defp refund_refused(turn, {:error, reason, _model_state})
       when reason in @refused_before_provider,
       do: put_allowance(turn, Allowance.refund_iteration(turn.allowance))

  defp refund_refused(turn, _response), do: turn

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

    Enum.reduce(calls, {:continue, turn, []}, fn
      # The turn already ended on a question: the Member answers it before
      # any later call of the batch may act (it could show a Proposal or
      # spend on the optimizer). Each one still gets a result, as the
      # provider requires.
      call, {:end_turn, acc, fingerprints} ->
        skipped = %{"error" => "skipped_after_question"}
        acc = append(acc, %{role: :tool_result, id: call.id, name: call.name, content: skipped})
        {:end_turn, acc, fingerprints}

      call, {:continue, acc, fingerprints} ->
        run_tool(call, acc, fingerprints)
    end)
  end

  defp run_tool(call, acc, fingerprints) do
    arguments = if is_map(call.arguments), do: call.arguments, else: %{}
    {content, workspace, call_control} = Tools.execute(call.name, arguments, acc.tool_context)
    Map.get(acc, :on_workspace, fn _workspace -> :ok end).(workspace)

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

    {call_control, acc, fingerprint(call.name, content, fingerprints)}
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

  defp append(turn, message), do: %{turn | messages: turn.messages ++ [message]}

  defp put_allowance(turn, allowance) do
    if report = Map.get(turn, :report_allowance), do: report.(allowance)
    %{turn | allowance: allowance}
  end

  # A limit that cuts a turn whose latest tool result is a service failure
  # (a backend that is down, not a misused tool) is caused by those tools:
  # the code tells the Member which tools failed and why, whatever the model
  # did before (quality battery task A7). Never a question.
  defp finish(turn, {:limit_reached, _limit} = outcome) do
    case failing_tools(turn.messages) do
      [] -> :ok
      failures -> turn.emit.(%{"type" => "assistant_message", "text" => failure_notice(failures)})
    end

    build_result(turn, outcome)
  end

  defp finish(turn, outcome), do: build_result(turn, outcome)

  # The tools of this turn whose latest result is a service failure, in the
  # order they were first called, when the turn's latest tool result is one.
  defp failing_tools(messages) do
    results =
      messages
      |> Enum.reverse()
      |> Enum.take_while(&(&1.role != :user))
      |> Enum.reverse()
      |> Enum.filter(&(&1.role == :tool_result))

    if results != [] and service_failure?(List.last(results).content) do
      latest = Map.new(results, &{&1.name, &1.content})

      results
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.filter(&service_failure?(latest[&1]))
      |> Enum.map(&{&1, failure_reason(latest[&1])})
    else
      []
    end
  end

  @service_failure ~r/_(failed|unavailable|timeout|error)\z/

  # A fixed meal whose Recipe is gone comes from the Member's own choice, not
  # from a service outage.
  defp service_failure?(%{"error" => "fixed_meal_unavailable"}), do: false

  defp service_failure?(%{"error" => error}) when is_binary(error),
    do: Regex.match?(@service_failure, error)

  defp service_failure?(_content), do: false

  # Only code-defined failure kinds reach the Member, never tool output.
  defp failure_reason(%{"error" => "optimizer_failed", "reason" => reason})
       when is_binary(reason),
       do: humanize(reason)

  defp failure_reason(%{"error" => error}), do: humanize(error)

  defp humanize(code) do
    if Regex.match?(~r/\A[a-z][a-z_]{0,40}\z/, code),
      do: String.replace(code, "_", " "),
      else: "unexpected error"
  end

  @tool_names %{
    "search_recipes" => "recipe search",
    "run_optimizer" => "meal plan optimizer",
    "lookup_prices" => "price lookup",
    "get_recipe" => "recipe details",
    "get_plan" => "saved plans",
    "reuse_plan" => "saved plans",
    "get_pantry" => "pantry"
  }

  defp failure_notice(failures) do
    tools =
      failures
      |> Enum.map(fn {name, reason} ->
        "#{Map.get(@tool_names, name, tool_label(name))} (#{reason})"
      end)
      |> Enum.join(", ")

    "I had to stop: some of the tools I need kept failing: #{tools}. " <>
      "This is a problem on our side, not with your request. Please try again later."
  end

  defp build_result(turn, outcome) do
    %{
      outcome: outcome,
      model_state: turn.model_state,
      messages: turn.messages,
      workspace: turn.tool_context.workspace,
      allowance: turn.allowance
    }
  end
end
