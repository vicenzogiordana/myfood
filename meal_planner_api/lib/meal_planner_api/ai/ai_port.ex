defmodule MealPlannerApi.AI.AIPort do
  @moduledoc """
  Behaviour for LLM/AI integrations (Gemini, OpenAI, etc.).

  Implementors wrap an AI provider with a structured interface.
  """

  @type stream_topic :: String.t()
  @type prompt :: String.t()
  @type opts :: keyword()

  @doc """
  Generates text synchronously from a prompt.

  Options (all optional):
  - `:system_prompt` — system instructions
  - `:max_output_tokens` — max tokens in response (default 2048)
  """
  @callback generate_text(prompt(), opts()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Starts async streaming chat. Results are broadcast to `topic` via Phoenix channels.

  The implementation must broadcast these events on the topic:
  - `ai_response_started` — when stream begins
  - `ai_response_chunk` — with `%{chunk: text, done: boolean}`
  - `ai_response_finished` — when stream ends
  - `ai_response_error` — with `%{error: reason}`
  """
  @callback stream_chat_completion(stream_topic(), prompt(), opts()) :: :ok | {:error, term()}
end
