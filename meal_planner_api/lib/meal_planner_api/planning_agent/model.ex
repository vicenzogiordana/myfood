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
        tools: [tool()],
        checkpoint: (state -> any())  # optional
      }

  A paid adapter calls `checkpoint` with its updated state after reserving
  spend and before the paid call, so the session keeps the reservation even
  when it kills the turn mid-call.

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
  @type request :: %{
          required(:instructions) => String.t(),
          required(:messages) => [message()],
          required(:tools) => [tool()],
          optional(:checkpoint) => (term() -> any())
        }
  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
  # `usage` is nil when the provider did not report it: missing, not zero.
  @type response :: %{text: String.t() | nil, tool_calls: [tool_call()], usage: usage() | nil}

  @doc """
  Builds the adapter state for one Planning Session. A paid adapter must
  refuse here when its spend or token caps are not configured.
  """
  @callback init(keyword()) :: {:ok, state :: term()} | {:error, term()}

  @doc "Answers one request with either assistant text or tool calls plus usage."
  @callback respond(state :: term(), request()) ::
              {:ok, response(), state :: term()} | {:error, term(), state :: term()}

  @doc """
  The part of the state that must survive a server restart (issue #107),
  such as the spend already used. It is stored, so it never holds
  credentials. Work whose outcome is unknown (a reserved call) is
  reconciled here, never replayed: its worst case counts as spent.
  """
  @callback recoverable(state :: term()) :: term()

  @doc """
  Rebuilds the state of a recovered Planning Session from `opts` (as
  `init/1`) and what `recoverable/1` kept. An adapter without these
  callbacks is recovered with `init/1` alone.
  """
  @callback recover(keyword(), recoverable :: term()) :: {:ok, state :: term()} | {:error, term()}

  @optional_callbacks recoverable: 1, recover: 2

  @doc "What `module` keeps of `state` across a restart, or `nil`."
  @spec recoverable(module(), term()) :: term()
  def recoverable(module, state) do
    if exported?(module, :recoverable, 1), do: module.recoverable(state), else: nil
  end

  @doc "Rebuilds the state of `module` for a recovered Planning Session."
  @spec recover(module(), keyword(), term()) :: {:ok, term()} | {:error, term()}
  def recover(module, opts, recoverable) do
    if exported?(module, :recover, 2),
      do: module.recover(opts, recoverable),
      else: module.init(opts)
  end

  defp exported?(module, name, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, name, arity)
end
