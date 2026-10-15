defmodule MealPlannerApiWeb.PlanningAgentChannel do
  @moduledoc """
  Thin Phoenix adapter over `MealPlannerApi.PlanningAgent.Session` (spec #93),
  living beside the legacy `planning:*` flow.

  Topic: `planning_agent:<household_id>`. The Household always comes from the
  socket's current membership; payloads never choose it.

  Incoming events:

    * `start_session` — `%{"range_from", "range_to", "slots"}` (slots default
      to lunch and dinner). Replies `%{session_id}` or
      `%{reason: "session_already_active" | "range_already_planned" | ...}`.
    * `give_consent` — records the Member's consent to external AI use.
    * `send_message` — `%{"text"}`; replies `:ok` or `%{reason: "consent_required" | "busy"}`.
    * `cancel_session` — ends the Household's session (its Member or the Owner).

  Outgoing: every session event is pushed as `agent_event` with its `type`
  and the `session_id`.
  """

  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApiWeb.ChannelCapability
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket

  @default_slots ["lunch", "dinner"]

  @impl true
  def join("planning_agent:" <> topic_account_id, _payload, socket) do
    membership = LoadCurrentMembershipSocket.membership_from_socket(socket)

    cond do
      is_nil(membership) or membership.status != :active ->
        {:error, %{reason: "forbidden"}}

      to_string(membership.account_id) != topic_account_id ->
        {:error, %{reason: "forbidden"}}

      true ->
        case ChannelCapability.authorize(membership) do
          :ok -> {:ok, assign(socket, :current_membership, membership)}
          {:error, :subscription_required} -> {:error, %{reason: "subscription_required"}}
        end
    end
  end

  @impl true
  def handle_in("start_session", payload, socket) do
    membership = socket.assigns.current_membership

    with {:ok, range} <- parse_range(payload),
         :ok <- check_eligible(membership.account_id),
         {:ok, %{session_id: session_id, pid: pid}} <-
           Session.start(
             %{
               account_id: membership.account_id,
               user_id: membership.user_id,
               membership_id: membership.id,
               role: membership.role,
               range: range,
               slots: Map.get(payload, "slots", @default_slots)
             },
             subscriber: self()
           ) do
      {:reply, {:ok, %{session_id: session_id}}, assign(socket, :session_pid, pid)}
    else
      {:error, reason} -> {:reply, {:error, %{reason: reason_string(reason)}}, socket}
    end
  end

  def handle_in("give_consent", _payload, socket) do
    with_own_session(socket, fn pid -> Session.record_consent(pid) end)
  end

  def handle_in("send_message", %{"text" => text}, socket) when is_binary(text) do
    with_own_session(socket, fn pid -> Session.send_message(pid, text) end)
  end

  def handle_in("cancel_session", _payload, socket) do
    membership = socket.assigns.current_membership

    case Session.whereis(membership.account_id) do
      nil ->
        {:reply, {:error, %{reason: "no_active_session"}}, socket}

      pid ->
        actor = %{membership_id: membership.id, owner?: membership.role == :owner}

        case Session.cancel(pid, actor) do
          :ok -> {:reply, {:ok, %{status: "cancelled"}}, assign(socket, :session_pid, nil)}
          {:error, reason} -> {:reply, {:error, %{reason: reason_string(reason)}}, socket}
        end
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_payload"}}, socket}

  @impl true
  def handle_info({:planning_agent_event, session_id, event}, socket) do
    push(socket, "agent_event", Map.put(event, "session_id", session_id))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp with_own_session(socket, fun) do
    case socket.assigns[:session_pid] do
      pid when is_pid(pid) ->
        case fun.(pid) do
          :ok -> {:reply, :ok, socket}
          {:error, reason} -> {:reply, {:error, %{reason: reason_string(reason)}}, socket}
        end

      _ ->
        {:reply, {:error, %{reason: "no_active_session"}}, socket}
    end
  catch
    :exit, _ ->
      {:reply, {:error, %{reason: "no_active_session"}}, assign(socket, :session_pid, nil)}
  end

  defp parse_range(payload) do
    with from when is_binary(from) <- Map.get(payload, "range_from"),
         to when is_binary(to) <- Map.get(payload, "range_to"),
         {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to) do
      {:ok, {from_date, to_date}}
    else
      _ -> {:error, :invalid_range}
    end
  end

  defp check_eligible(account_id) do
    if AccountAccess.eligible?(account_id), do: :ok, else: {:error, :subscription_required}
  end

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason), do: "invalid_payload"
end
