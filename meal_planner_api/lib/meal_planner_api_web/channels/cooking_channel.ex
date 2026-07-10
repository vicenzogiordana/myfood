defmodule MealPlannerApiWeb.CookingChannel do
  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Services.CookingService
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket

  @impl true
  def join("cooking:" <> account_and_session, _payload, socket) do
    topic_account_id =
      account_and_session
      |> String.split(":", parts: 2)
      |> List.first()

    membership = LoadCurrentMembershipSocket.membership_from_socket(socket)

    cond do
      is_nil(membership) ->
        {:error, %{reason: "forbidden"}}

      to_string(membership.account_id) != topic_account_id ->
        {:error, %{reason: "forbidden"}}

      membership.status != :active ->
        {:error, %{reason: "forbidden"}}

      true ->
        {:ok,
         socket
         |> assign(:account_id, topic_account_id)
         |> assign(:current_membership, membership)}
    end
  end

  @impl true
  def handle_in("start_session", %{"scheduled_meal_id" => meal_id}, socket)
      when is_binary(meal_id) do
    user = socket.assigns.current_user
    membership = socket.assigns.current_membership

    # Spec `membership-scoped-channels` §"handle_in with cross-Account entity
    # id": verify the entity id belongs to current_membership.account_id
    # BEFORE mutation/delegation.
    try do
      case PlanningRepo.get_scheduled_meal_for_account(membership.account_id, meal_id) do
        nil ->
          {:reply, {:error, %{reason: "meal_not_in_account"}}, socket}

        _meal ->
          case CookingService.start_session(user, meal_id) do
            {:ok, session} ->
              push(socket, "session_started", session)
              {:noreply, socket}

            {:error, reason} ->
              {:reply, {:error, %{reason: reason}}, socket}
          end
      end
    rescue
      Ecto.Query.CastError ->
        {:reply, {:error, %{reason: "invalid_meal_id"}}, socket}
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
    session_id = Map.get(payload, "session_id") || Map.get(socket.assigns, :session_id)
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
