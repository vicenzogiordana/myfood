defmodule MealPlannerApi.AI.GeminiAdapter do
  @moduledoc """
  Adapter wrapping the existing `GeminiClient` to implement `AIPort`.

  Configuration via application env:
  - `:gemini_model` — model name (default: "gemini-2.5-flash-lite")
  - `:gemini_base_url` — base URL
  - `:gemini_timeout_ms` — request timeout in ms (default: 15_000)
  """

  @behaviour MealPlannerApi.AI.AIPort

  @impl true
  def generate_text(prompt, opts) do
    MealPlannerApi.AI.GeminiClient.generate_text(prompt, opts)
  end

  @impl true
  def stream_chat_completion(topic, prompt, opts) do
    MealPlannerApi.AI.GeminiClient.stream_chat_completion(topic, prompt, opts)
  end
end
