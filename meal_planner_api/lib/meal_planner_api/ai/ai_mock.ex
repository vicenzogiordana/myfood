defmodule MealPlannerApi.AI.AIMock do
  @moduledoc """
  Test double for `AIPort`.

  Returns configurable responses and tracks calls for assertion.
  """

  @behaviour MealPlannerApi.AI.AIPort

  @impl true
  def generate_text(_prompt, _opts) do
    send(self(), {:ai_mock_call, :generate_text})
    {:ok, "mock response"}
  end

  @impl true
  def stream_chat_completion(_topic, _prompt, _opts) do
    send(self(), {:ai_mock_call, :stream_chat})
    :ok
  end
end
