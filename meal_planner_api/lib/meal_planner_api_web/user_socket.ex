defmodule MealPlannerApiWeb.UserSocket do
  use Phoenix.Socket

  channel "ai_chat:*", MealPlannerApiWeb.AIChannel
  channel "calendar:*", MealPlannerApiWeb.CalendarChannel
  channel "planning:*", MealPlannerApiWeb.PlanningChannel
  channel "cooking:*", MealPlannerApiWeb.CookingChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case MealPlannerApi.Auth.Guardian.resource_from_token(token) do
      {:ok, user, _claims} ->
        {:ok, assign(socket, :current_user, user)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket) do
    "user_socket:" <> socket.assigns.current_user.id
  end
end
