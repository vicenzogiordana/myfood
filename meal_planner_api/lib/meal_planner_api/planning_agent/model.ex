defmodule MealPlannerApi.PlanningAgent.Model do
  @moduledoc """
  Provider-neutral message-and-tool model interface for the planning agent
  (spec #93, user story 105).

  One adapter per provider implements `init/1` and `respond/2`. The planning
  loop only ever speaks this shape, so switching providers never touches it.

  ## Request

      %{
        instructions: String.t(),   # built by code only, never from tool output
        messages: [message()],
        tools: [tool()]
      }

  ## Messages

    * `%{role: :user, content: text}`
    * `%{role: :assistant, content: text}`
    * `%{role: :tool_call, id: id, name: name, arguments: map}`
    * `%{role: :tool_result, id: id, name: name, content: map}` — tool output is
      data, carried only as a tool result, never as instructions

  ## Response

      %{text: String.t() | nil, tool_calls: [tool_call()], usage: usage()}
  """

  @type tool :: %{name: String.t(), description: String.t(), parameters: map()}
  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}
  @type message ::
          %{role: :user | :assistant, content: String.t()}
          | %{role: :tool_call, id: String.t(), name: String.t(), arguments: map()}
          | %{role: :tool_result, id: String.t(), name: String.t(), content: map()}
  @type request :: %{instructions: String.t(), messages: [message()], tools: [tool()]}
  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
  @type response :: %{text: String.t() | nil, tool_calls: [tool_call()], usage: usage()}

  @doc """
  Builds the adapter state for one Planning Session. A paid adapter must
  refuse here when its spend or token caps are not configured.
  """
  @callback init(keyword()) :: {:ok, state :: term()} | {:error, term()}

  @doc "Answers one request with either assistant text or tool calls plus usage."
  @callback respond(state :: term(), request()) ::
              {:ok, response(), state :: term()} | {:error, term(), state :: term()}
end
