defmodule MealPlannerApiWeb.CookingChannel do
  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.CookingAssistant

  @impl true
  def join("cooking:" <> account_and_session, _payload, socket) do
    user = socket.assigns.current_user

    with [account_id, session_id] <- String.split(account_and_session, ":", parts: 2),
         true <- user.account_id == account_id,
         {:ok, _state} <- CookingAssistant.session_state(user, session_id) do
      {:ok, assign(socket, :session_id, session_id)}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in("ask_assistant", %{"message" => message} = payload, socket)
      when is_binary(message) do
    user = socket.assigns.current_user
    request_id = Map.get(payload, "request_id", build_request_id())
    content_type = Map.get(payload, "content_type", "text")

    broadcast!(socket, "assistant_typing", %{request_id: request_id})

    case CookingAssistant.answer_question(user, socket.assigns.session_id, message, content_type) do
      {:ok, result} ->
        chunks = chunk_text(result.message)

        Enum.each(chunks, fn chunk ->
          broadcast!(socket, "assistant_chunk", %{
            request_id: request_id,
            chunk: chunk,
            done: false
          })
        end)

        broadcast!(socket, "assistant_chunk", %{request_id: request_id, chunk: "", done: true})

        broadcast!(socket, "assistant_finished", %{
          request_id: request_id,
          session_id: result.session_id
        })

        {:reply, {:ok, Map.put(result, :request_id, request_id)}, socket}

      {:error, reason} ->
        payload = %{request_id: request_id, reason: serialize_reason(reason)}
        broadcast!(socket, "assistant_error", payload)
        {:reply, {:error, payload}, socket}
    end
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  defp chunk_text(text) do
    text
    |> String.split(" ")
    |> Enum.chunk_every(6)
    |> Enum.map(&Enum.join(&1, " "))
  end

  defp build_request_id do
    "req_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"
end
