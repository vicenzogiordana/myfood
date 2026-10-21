defmodule MealPlannerApiWeb.PlanningAgentChannel do
  @moduledoc """
  Thin Phoenix adapter over `MealPlannerApi.PlanningAgent.Session` (spec #93),
  the only planning flow since the legacy planner was switched off (issue
  #110).

  Topics: `planning:<household_id>` and its rollout alias
  `planning_agent:<household_id>`; both serve this agent flow only. The
  Household always comes from the socket's current membership; payloads never
  choose it.

  Incoming events:

    * `start_session` — `%{"range_from", "range_to", "slots"}` (slots default
      to lunch and dinner). Replies `%{session_id}` or
      `%{reason: "session_already_active" | "range_already_planned" | ...}`;
      a failure without a typed reason replies `internal_error`.
    * `resume_session` — the session Member's return after leaving or a
      server restart, within the absence grace. Replies `%{session_id,
      proposal}` (the last valid Proposal, or `nil`) or
      `%{reason: "forbidden" | "no_session" | "session_busy"}` (`session_busy`:
      the running session did not answer in time; retry later).
    * `give_consent` — records the Member's consent to external AI use.
    * `send_message` — `%{"text"}`; replies `:ok` or
      `%{reason: "consent_required" | "busy" | "invalid_message" | "message_too_long" |
      "session_budget_exhausted"}`. After a `limit_reached` event a new
      message is accepted and authorizes continuing by itself.
    * `authorize_continuation` — the session Member authorizes continuing
      the same request after a `limit_reached` event; replies `:ok` or
      `%{reason: "forbidden" | "no_limit_reached"}`.
    * `save_recipe` — `%{"recipe_id"}`; the session Member's explicit save of
      a dictated Recipe Draft. Replies `%{recipe_id, name, origin}` or
      `%{reason: "forbidden" | "busy" | "not_found" | "not_dictated"}`.
    * `stop` — Stop: halts the agent's current work; the session, Workspace
      and last valid Proposal survive. Only the session's Member; replies
      `%{status: "stopped"}` or `%{reason: "forbidden" | "no_active_session"}`.
    * `cancel_session` — Cancel: ends the Household's session and discards its
      Workspace (its Member or the Owner), also one waiting for recovery after
      a restart; replies `%{status: "cancelled"}` or
      `%{reason: "forbidden" | "no_active_session"}`.
    * `confirm` — `%{"proposal_id"}`; the session Member's confirmation of the
      exact displayed Proposal (issue #169). Replies `%{confirmation_id,
      meals_count, shopping_lines_count}` (also for a replay after the session
      ended) or `%{reason: "forbidden" | "busy" | "member_absent" |
      "stale_proposal" | "approval_required" | "revalidation_conflict" |
      "unresolved"}`.
    * `confirmation_status` — `%{"proposal_id"}`; replies `%{status:
      "confirmed", confirmation_id, meals_count, shopping_lines_count}`,
      `%{status: "not_found"}` or `%{status: "unknown"}`.
    * `approve_deviations` — `%{"proposal_id"}`; the session Member's
      Deviation Approval of that exact Proposal. Replies `:ok` or
      `%{reason: "forbidden" | "busy" | "stale_proposal" | "no_deviations" |
      "session_not_active"}`.
    * `approve_absence_exception` — `%{"member_id", "restriction" => %{"kind",
      "value"}, "meals" => [%{"date", "slot"}]}`; replies `:ok` or
      `%{reason: "forbidden" | "busy" | "invalid_absence_exception" |
      "session_not_active"}`.

  See `docs/CHANNELS.md` for the full client contract.

  Outgoing: every session event is pushed as `agent_event` with its `type`
  and the `session_id`.
  """

  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.Planning.Restrictions
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApiWeb.ChannelCapability
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket

  @default_slots ["lunch", "dinner"]

  # Restriction names a client may send, mapped to the atoms of
  # `MealPlannerApi.Planning.Restrictions` without creating new atoms.
  @restrictions Map.new(
                  Enum.map(Restrictions.diets(), &{{"diet", Atom.to_string(&1)}, {:diet, &1}}) ++
                    Enum.map(
                      Restrictions.allergen_tags(),
                      &{{"allergy", Atom.to_string(&1)}, {:allergy, &1}}
                    )
                )

  @impl true
  def join("planning:" <> topic_account_id, payload, socket),
    do: join_household(topic_account_id, payload, socket)

  def join("planning_agent:" <> topic_account_id, payload, socket),
    do: join_household(topic_account_id, payload, socket)

  defp join_household(topic_account_id, _payload, socket) do
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
  # A non-map payload falls through to the invalid_payload clause below.
  def handle_in("start_session", payload, socket) when is_map(payload) do
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

  def handle_in("resume_session", _payload, socket) do
    membership = socket.assigns.current_membership

    attrs = %{
      account_id: membership.account_id,
      user_id: membership.user_id,
      membership_id: membership.id
    }

    case Session.resume(attrs, subscriber: self()) do
      {:ok, %{session_id: session_id, pid: pid, proposal: proposal}} ->
        {:reply, {:ok, %{session_id: session_id, proposal: proposal}},
         assign(socket, :session_pid, pid)}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason_string(reason)}}, socket}
    end
  end

  def handle_in("give_consent", _payload, socket) do
    with_own_session(socket, fn pid -> Session.record_consent(pid) end)
  end

  # A missing or non-binary text still reaches the session, which refuses it
  # with invalid_message as documented.
  def handle_in("send_message", payload, socket) when is_map(payload) do
    with_own_session(socket, fn pid -> Session.send_message(pid, Map.get(payload, "text")) end)
  end

  def handle_in("authorize_continuation", _payload, socket) do
    membership_id = socket.assigns.current_membership.id
    with_own_session(socket, fn pid -> Session.authorize_continuation(pid, membership_id) end)
  end

  def handle_in("save_recipe", %{"recipe_id" => recipe_id}, socket) when is_binary(recipe_id) do
    membership_id = socket.assigns.current_membership.id

    case socket.assigns[:session_pid] do
      pid when is_pid(pid) ->
        case Session.save_recipe(pid, membership_id, recipe_id) do
          {:ok, saved} -> {:reply, {:ok, saved}, socket}
          {:error, reason} -> {:reply, {:error, %{reason: reason_string(reason)}}, socket}
        end

      _ ->
        {:reply, {:error, %{reason: "no_active_session"}}, socket}
    end
  catch
    :exit, _ ->
      {:reply, {:error, %{reason: "no_active_session"}}, assign(socket, :session_pid, nil)}
  end

  def handle_in("stop", _payload, socket) do
    with_household_session(socket, fn pid, actor ->
      case Session.stop(pid, actor) do
        :ok -> {:reply, {:ok, %{status: "stopped"}}, socket}
        {:error, reason} -> {:reply, {:error, %{reason: reason_string(reason)}}, socket}
      end
    end)
  end

  def handle_in("cancel_session", _payload, socket) do
    membership = socket.assigns.current_membership

    if Session.whereis(membership.account_id) do
      with_household_session(socket, fn pid, actor ->
        cancel_reply(Session.cancel(pid, actor), socket)
      end)
    else
      # No process runs it: a session waiting for recovery after a restart.
      actor = %{membership_id: membership.id, owner?: membership.role == :owner}

      case Session.cancel_recoverable(membership.account_id, actor) do
        {:error, reason} when reason in [:no_session, :session_running] ->
          {:reply, {:error, %{reason: "no_active_session"}}, socket}

        result ->
          cancel_reply(result, socket)
      end
    end
  end

  # Confirmation needs no running session: a replay after the session ended
  # returns the original result.
  def handle_in("confirm", %{"proposal_id" => proposal_id}, socket)
      when is_binary(proposal_id) do
    membership = socket.assigns.current_membership

    case Session.confirm(membership.account_id, membership.id, proposal_id) do
      {:ok, summary} ->
        {:reply, {:ok, summary_data(summary)}, assign(socket, :session_pid, nil)}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason_string(reason)}}, socket}
    end
  end

  def handle_in("confirmation_status", %{"proposal_id" => proposal_id}, socket)
      when is_binary(proposal_id) do
    account_id = socket.assigns.current_membership.account_id

    reply =
      case Session.confirmation_status(account_id, proposal_id) do
        {:confirmed, summary} -> Map.put(summary_data(summary), :status, "confirmed")
        status when status in [:not_found, :unknown] -> %{status: Atom.to_string(status)}
      end

    {:reply, {:ok, reply}, socket}
  end

  def handle_in("approve_deviations", %{"proposal_id" => proposal_id}, socket)
      when is_binary(proposal_id) do
    membership = socket.assigns.current_membership

    membership.account_id
    |> Session.approve_deviations(membership.id, proposal_id)
    |> ok_reply(socket)
  end

  def handle_in("approve_absence_exception", payload, socket) when is_map(payload) do
    membership = socket.assigns.current_membership

    case parse_absence_exception(payload) do
      {:ok, exception} ->
        membership.account_id
        |> Session.approve_absence_exception(membership.id, exception)
        |> ok_reply(socket)

      :error ->
        {:reply, {:error, %{reason: "invalid_absence_exception"}}, socket}
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

  defp ok_reply(:ok, socket), do: {:reply, :ok, socket}

  defp ok_reply({:error, reason}, socket),
    do: {:reply, {:error, %{reason: reason_string(reason)}}, socket}

  defp summary_data(summary),
    do: Map.take(summary, [:confirmation_id, :meals_count, :shopping_lines_count])

  # `{"member_id", "restriction" => {"kind", "value"}, "meals" => [{"date",
  # "slot"}]}`: a malformed one never reaches the session.
  defp parse_absence_exception(%{
         "member_id" => member_id,
         "restriction" => %{"kind" => kind, "value" => value},
         "meals" => [_ | _] = meals
       })
       when is_binary(member_id) and is_binary(kind) and is_binary(value) do
    with {:ok, restriction} <- Map.fetch(@restrictions, {kind, value}),
         {:ok, meals} <- parse_meals(meals) do
      {:ok, %{member_id: member_id, restriction: restriction, meals: meals}}
    end
  end

  defp parse_absence_exception(_payload), do: :error

  defp parse_meals(meals) do
    Enum.reduce_while(meals, {:ok, []}, fn
      %{"date" => date, "slot" => slot}, {:ok, acc} when is_binary(date) and is_binary(slot) ->
        case Date.from_iso8601(date) do
          {:ok, date} -> {:cont, {:ok, acc ++ [{date, slot}]}}
          {:error, _} -> {:halt, :error}
        end

      _meal, _acc ->
        {:halt, :error}
    end)
  end

  defp cancel_reply(:ok, socket),
    do: {:reply, {:ok, %{status: "cancelled"}}, assign(socket, :session_pid, nil)}

  defp cancel_reply({:error, reason}, socket),
    do: {:reply, {:error, %{reason: reason_string(reason)}}, socket}

  # Stop and Cancel act on the Household's session whichever socket opened
  # it; the session itself authorizes the actor.
  defp with_household_session(socket, fun) do
    membership = socket.assigns.current_membership

    case Session.whereis(membership.account_id) do
      nil ->
        {:reply, {:error, %{reason: "no_active_session"}}, socket}

      pid ->
        fun.(pid, %{membership_id: membership.id, owner?: membership.role == :owner})
    end
  catch
    # The session can end between the lookup and the call.
    :exit, _ ->
      {:reply, {:error, %{reason: "no_active_session"}}, assign(socket, :session_pid, nil)}
  end

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

  # Typed refusals are atoms. Anything else (a changeset or an unexpected
  # tuple) is an internal failure, never blamed on the payload, and its
  # detail stays on the server.
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason), do: "internal_error"
end
