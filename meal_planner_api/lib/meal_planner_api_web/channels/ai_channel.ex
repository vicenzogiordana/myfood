defmodule MealPlannerApiWeb.AIChannel do
  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.AI
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket

  # Note (task 3.12): unlike planning/cooking/calendar, this channel's topic
  # is `ai_chat:<room_id>` — an opaque chat/session identifier, NOT
  # `ai:<account_id>`. There is no account_id embedded in the topic to
  # cross-check against current_membership.account_id, so join/3 enforces
  # "the socket carries an active membership" (nil/non-active rejected)
  # rather than a topic-vs-membership account match. See apply-progress.md
  # for the full deviation writeup.
  @impl true
  def join("ai_chat:" <> room_id, _payload, socket) do
    membership = LoadCurrentMembershipSocket.membership_from_socket(socket)

    cond do
      is_nil(membership) ->
        {:error, %{reason: "forbidden"}}

      membership.status != :active ->
        {:error, %{reason: "forbidden"}}

      true ->
        {:ok,
         socket
         |> assign(:room_id, room_id)
         |> assign(:current_membership, membership)}
    end
  end

  @impl true
  def handle_in("new_message", %{"message" => message} = payload, socket)
      when is_binary(message) do
    user = socket.assigns.current_user
    membership = socket.assigns.current_membership
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
          account_id: membership.account_id,
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
