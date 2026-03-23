defmodule MealPlannerApi.AI.Client do
  @moduledoc """
  Behaviour for LLM clients (Gemini, OpenAI, etc.).
  """

  @type stream_topic :: String.t()
  @type prompt :: String.t()

  @callback stream_chat_completion(stream_topic(), prompt(), keyword()) :: :ok | {:error, term()}
  @callback generate_text(prompt(), keyword()) :: {:ok, String.t()} | {:error, term()}
end
