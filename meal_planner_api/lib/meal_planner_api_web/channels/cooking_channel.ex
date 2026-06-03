defmodule MealPlannerApiWeb.CookingChannel do
  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.Services.CookingService

  @impl true
  def join("cooking:" <> _account_and_session, _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("start_session", %{"scheduled_meal_id" => meal_id}, socket)
      when is_binary(meal_id) do
    user = socket.assigns.current_user

    case CookingService.start_session(user, meal_id) do
      {:ok, session} ->
        push(socket, "session_started", session)
        {:noreply, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("start_session", _payload, socket) do
    {:reply, {:error, %{reason: "missing_scheduled_meal_id"}}, socket}
  end

  @impl true
  def handle_in("get_state", %{"session_id" => session_id}, socket)
      when is_binary(session_id) do
    user = socket.assigns.current_user

    case CookingService.session_state(user, session_id) do
      {:ok, state} ->
        {:reply, {:ok, state}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("get_state", _payload, socket) do
    {:reply, {:error, %{reason: "missing_session_id"}}, socket}
  end

  @impl true
  def handle_in(
        "track_step",
        %{"session_id" => session_id, "recipe_step_id" => step_id, "status" => status} = payload,
        socket
      )
      when is_binary(session_id) and is_binary(step_id) do
    user = socket.assigns.current_user

    atom_status =
      case status do
        "started" -> :started
        "paused" -> :paused
        "completed" -> :completed
        "error" -> :error
        _ -> :started
      end

    extra = Map.drop(payload, ["session_id", "recipe_step_id", "status"])

    case CookingService.track_step(user, session_id, step_id, atom_status, extra) do
      {:ok, result} ->
        push(socket, "step_tracked", result)
        {:noreply, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("track_step", _payload, socket) do
    {:reply, {:error, %{reason: "missing_fields"}}, socket}
  end

  @impl true
  def handle_in("finish_session", %{"session_id" => session_id}, socket)
      when is_binary(session_id) do
    user = socket.assigns.current_user

    case CookingService.finish_session(user, session_id) do
      {:ok, result} ->
        push(socket, "session_finished", result)
        {:noreply, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("finish_session", _payload, socket) do
    {:reply, {:error, %{reason: "missing_session_id"}}, socket}
  end

  @impl true
  def handle_in("ask_assistant", %{"message" => message} = payload, socket)
      when is_binary(message) do
    user = socket.assigns.current_user
    session_id = Map.get(payload, "session_id") || socket.assigns.session_id
    content_type = Map.get(payload, "content_type", "text")

    if session_id do
      case CookingService.answer_question(user, session_id, message, content_type) do
        {:ok, result} ->
          push(socket, "assistant_reply", result)
          {:noreply, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: reason}}, socket}
      end
    else
      {:reply, {:error, %{reason: "no_active_session"}}, socket}
    end
  end

  def handle_in("ask_assistant", _payload, socket) do
    {:reply, {:error, %{reason: "missing_message"}}, socket}
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "event_not_implemented"}}, socket}
  end
end
