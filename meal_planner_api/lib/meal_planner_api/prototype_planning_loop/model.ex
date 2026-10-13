# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule MealPlannerApi.PrototypePlanningLoop.Model do
  @moduledoc """
  Interface between the loop and a model. Both implementations speak the
  OpenAI Responses API item shape (string keys):

    * request `input`: user messages `%{"role" => "user", "content" => text}`,
      prior output items verbatim, and
      `%{"type" => "function_call_output", "call_id" => id, "output" => json}`.
    * response `output`: items such as
      `%{"type" => "function_call", "call_id" => id, "name" => name, "arguments" => json}`
      and `%{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}`.
  """

  @type request :: %{instructions: String.t(), input: [map()], tools: [map()]}
  @type usage :: %{
          input_tokens: integer(),
          cached_input_tokens: integer(),
          output_tokens: integer()
        }
  @type response :: %{output: [map()], usage: usage(), spend: map() | nil}

  @callback respond(state :: term(), request()) ::
              {:ok, response(), term()} | {:error, String.t()}
end
