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
    topic = "ai_chat:" <> room_id
    budget = Budgets.resolve_for(user, params)
    inventory = Inventory.available_for(user, params)
    subscription = Subscriptions.policy_for(user.subscription_tier)
    message_history = Messages.parse_history(params)

    client().stream_chat_completion(topic, prompt,
      user: user,
      request_id: Map.get(params, "request_id"),
      budget: Budgets.serialize(budget),
      inventory_items: Inventory.names(inventory),
      subscription: subscription,
      persona: Messages.persona(),
      message_history: message_history
    )
  end

  @spec generate_text(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_text(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    client().generate_text(prompt, opts)
  end

  defp client do
    Application.get_env(:meal_planner_api, :ai_client, MealPlannerApi.AI.MockClient)
  end
end
