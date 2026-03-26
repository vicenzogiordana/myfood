defmodule MealPlannerApi.AI do
  @moduledoc """
  AI context boundary.
  Orchestrates requests and delegates provider calls to the configured client.
  """

  alias MealPlannerApi.Budgets
  alias MealPlannerApi.Inventory
  alias MealPlannerApi.Messages
  alias MealPlannerApi.Subscriptions
  alias MealPlannerApi.Accounts.User

  @spec stream_response(String.t(), String.t(), User.t(), map()) :: :ok | {:error, term()}
  def stream_response(room_id, prompt, %User{} = user, params \\ %{})
      when is_binary(room_id) and is_binary(prompt) do
    with {:ok, client_module} <- client(),
         :ok <- ensure_client_ready(client_module) do
      topic = "ai_chat:" <> room_id
      budget = Budgets.resolve_for(user, params)
      inventory = Inventory.available_for(user, params)
      subscription = Subscriptions.policy_for_account(user.account_id)
      message_history = Messages.parse_history(params)

      client_module.stream_chat_completion(topic, prompt,
        user: user,
        request_id: Map.get(params, "request_id"),
        budget: Budgets.serialize(budget),
        inventory_items: Inventory.names(inventory),
        subscription: subscription,
        persona: Messages.persona(),
        message_history: message_history
      )
    end
  end

  @spec generate_text(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_text(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    with {:ok, client_module} <- client(),
         :ok <- ensure_client_ready(client_module) do
      client_module.generate_text(prompt, opts)
    end
  end

  defp client do
    case Application.get_env(:meal_planner_api, :ai_client) do
      nil ->
        {:error, :ai_client_not_configured}

      MealPlannerApi.AI.MockClient ->
        if current_env() == :test,
          do: {:ok, MealPlannerApi.AI.MockClient},
          else: {:error, :ai_mock_client_forbidden}

      module when is_atom(module) ->
        {:ok, module}

      _ ->
        {:error, :invalid_ai_client_configuration}
    end
  end

  defp ensure_client_ready(MealPlannerApi.AI.GeminiClient) do
    case System.get_env("GEMINI_API_KEY") do
      nil -> {:error, :missing_gemini_api_key}
      "" -> {:error, :missing_gemini_api_key}
      _ -> :ok
    end
  end

  defp ensure_client_ready(_), do: :ok

  defp current_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env()
    else
      :prod
    end
  end
end
