defmodule MealPlannerApiWeb.AIChannel do
  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.AI

  @impl true
  def join("ai_chat:" <> room_id, _payload, socket) do
    {:ok, assign(socket, :room_id, room_id)}
  end

  @impl true
  def handle_in("new_message", %{"message" => message} = payload, socket)
      when is_binary(message) do
    user = socket.assigns.current_user
    request_id = Map.get(payload, "request_id", build_request_id())

    case AI.stream_response(socket.assigns.room_id, message, user, %{
           "messages" => Map.get(payload, "messages", []),
           "weekly_budget_cents" => Map.get(payload, "weekly_budget_cents"),
           "currency" => Map.get(payload, "currency"),
           "inventory_items" => Map.get(payload, "inventory_items"),
           "request_id" => request_id
         }) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        push(socket, "ai_response_error", %{
          request_id: request_id,
          account_id: user.account_id,
          error: inspect(reason)
        })

        {:reply, {:error, %{reason: "ai_stream_start_failed"}}, socket}
    end
  end

  def handle_in("new_message", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  defp build_request_id do
    "req_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
