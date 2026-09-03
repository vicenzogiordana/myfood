defmodule MealPlannerApiWeb.PlanningChannel do
  @moduledoc """
  Phoenix Channel para el flujo de planificación v2 con streaming via Phoenix Channels.

  El canal delega la lógica pesada a `GenerationServer` (un GenServer por account_id).
  `GenerationServer` hace broadcast directo al `channel_pid` del socket.

  Eventos entrantes del cliente:
  - `generate_menu` — inicia generación de menú (usa GenerationServer)
  - `chat` — mensaje de modificación del usuario (usa GenerationServer)
  - `confirm_proposal` — confirma propuesta (usa PlanningChatService, backward compat)
  - `reject_proposal` — rechaza propuesta (usa PlanningChatService, backward compat)

  Eventos salientes (broadcast):
  - `generation_started` — generación iniciada
  - `proposal_ready` — propuesta disponible
  - `proposal_confirmed` — propuesta confirmada
  - `proposal_rejected` — propuesta rechazada
  - `generation_error` — error durante generación
  - `proposal_update` — propuesta actualizada tras modificación de usuario
  """
  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.Generation.{PlanningSessionServer, Server}
  alias MealPlannerApi.Services.PlanningChatService
  alias MealPlannerApiWeb.ChannelCapability
  alias MealPlannerApiWeb.Channels.IntentAtomizer
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket

  @impl true
  def join("planning:" <> topic_account_id, _payload, socket) do
    membership = LoadCurrentMembershipSocket.membership_from_socket(socket)

    cond do
      is_nil(membership) ->
        {:error, %{reason: "forbidden"}}

      to_string(membership.account_id) != topic_account_id ->
        {:error, %{reason: "forbidden"}}

      membership.status != :active ->
        {:error, %{reason: "forbidden"}}

      true ->
        case ChannelCapability.authorize(membership) do
          :ok ->
            {:ok,
             socket
             |> assign(:account_id, topic_account_id)
             |> assign(:current_membership, membership)}

          {:error, :subscription_required} ->
            {:error, %{reason: "subscription_required"}}
        end
    end
  end

  @impl true
  def handle_in("generate_menu", payload, socket) do
    user = socket.assigns.current_user
    membership = socket.assigns.current_membership
    request_id = Map.get(payload, "request_id", build_request_id())

    # Constraints viene del payload (date_from, date_to, budget_cents, etc.)
    constraints = Map.get(payload, "constraints", %{}) |> Map.merge(payload)

    case Server.start_generation(membership.account_id, user.id, constraints, socket.channel_pid) do
      {:ok, run_id} ->
        broadcast!(socket, "generation_started", %{request_id: request_id, run_id: run_id})
        {:reply, {:ok, %{request_id: request_id, run_id: run_id}}, socket}

      {:error, :already_running} ->
        {:reply, {:error, %{request_id: request_id, reason: "generation_in_progress"}}, socket}

      {:error, reason} ->
        payload = %{request_id: request_id, reason: serialize_reason(reason)}
        broadcast!(socket, "generation_error", payload)
        {:reply, {:error, payload}, socket}
    end
  end

  def handle_in("swap_constraints", payload, socket) do
    user = socket.assigns.current_user
    request_id = Map.get(payload, "request_id", build_request_id())
    base_payload = Map.get(payload, "base_payload", %{})
    constraints = Map.get(payload, "constraints", %{})

    broadcast!(socket, "generation_started", %{
      request_id: request_id,
      reason: "constraint_update"
    })

    case PlanningChatService.regenerate_menu(user, base_payload, constraints) do
      {:ok, result} ->
        event = %{
          request_id: request_id,
          run_id: result.run.id,
          proposal_id: result.proposal.id,
          date_from: Date.to_iso8601(result.date_from),
          date_to: Date.to_iso8601(result.date_to),
          proposal: result.proposal_json,
          applied_constraints: constraints
        }

        broadcast!(socket, "proposal_ready", event)
        {:reply, {:ok, event}, socket}

      {:error, reason} ->
        error_payload = %{request_id: request_id, reason: serialize_reason(reason)}
        broadcast!(socket, "generation_error", error_payload)
        {:reply, {:error, error_payload}, socket}
    end
  end

  @impl true
  def handle_in("chat", %{"message" => message, "proposal_id" => proposal_id}, socket) do
    membership = socket.assigns.current_membership

    # Obtener el PID del GenerationServer para este account
    case Registry.lookup(
           MealPlannerApi.Generation.Generations,
           {:generation, membership.account_id}
         ) do
      [{server_pid, _}] ->
        Server.chat(server_pid, proposal_id, message)
        {:noreply, socket}

      [] ->
        {:reply, {:error, %{reason: "no_active_generation"}}, socket}
    end
  end

  def handle_in("confirm_proposal", %{"proposal_id" => proposal_id}, socket) do
    user = socket.assigns.current_user
    membership = socket.assigns.current_membership

    # Primero intentar con GenerationServer (si existe para este account)
    case Registry.lookup(
           MealPlannerApi.Generation.Generations,
           {:generation, membership.account_id}
         ) do
      [{server_pid, _}] ->
        case Server.confirm(server_pid, proposal_id) do
          {:ok, result} ->
            {:reply, {:ok, result}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: serialize_reason(reason)}}, socket}
        end

      [] ->
        # Fallback: usar PlanningChatService (REST API backward compat)
        # Catch exceptions from service to return graceful errors
        try do
          case PlanningChatService.confirm_proposal(user, proposal_id) do
            {:ok, result} ->
              event = Map.put(result, :status, "confirmed")
              broadcast!(socket, "proposal_confirmed", event)
              {:reply, {:ok, event}, socket}

            {:error, reason} ->
              {:reply, {:error, %{reason: serialize_reason(reason)}}, socket}
          end
        rescue
          Ecto.NoResultsError ->
            {:reply, {:error, %{reason: "not_found"}}, socket}

          Ecto.Query.CastError ->
            {:reply, {:error, %{reason: "invalid_proposal_id"}}, socket}
        end
    end
  end

  def handle_in("reject_proposal", %{"proposal_id" => proposal_id}, socket) do
    user = socket.assigns.current_user
    membership = socket.assigns.current_membership

    case Registry.lookup(
           MealPlannerApi.Generation.Generations,
           {:generation, membership.account_id}
         ) do
      [{server_pid, _}] ->
        Server.reject(server_pid, proposal_id)
        {:noreply, socket}

      [] ->
        # Fallback: usar PlanningChatService (REST API backward compat)
        # Catch exceptions from service to return graceful errors
        try do
          case PlanningChatService.reject_proposal(user, proposal_id) do
            {:ok, result} ->
              event = Map.put(result, :status, "rejected")
              broadcast!(socket, "proposal_rejected", event)
              {:reply, {:ok, event}, socket}

            {:error, reason} ->
              {:reply, {:error, %{reason: serialize_reason(reason)}}, socket}
          end
        rescue
          Ecto.NoResultsError ->
            {:reply, {:error, %{reason: "not_found"}}, socket}

          Ecto.Query.CastError ->
            {:reply, {:error, %{reason: "invalid_proposal_id"}}, socket}
        end
    end
  end

  def handle_in("start_planning", payload, socket) do
    # Phase 4 PR4 — capability re-check fires here too, not only at join/3.
    # If the Account's trial/entitlement expired mid-session, refuse the
    # start with `:subscription_required`. The join-time guard would have
    # already admitted the socket; this handler enforces the same rule on
    # every new planning attempt.
    #
    # Session-server ownership: PR3's `PlanningSessionSupervisor` is a
    # DynamicSupervisor but its `start_session/4` helper builds a child
    # spec whose `start:` args list unpacks the keyword list as separate
    # Erlang args (`apply(M, F, [{:k, v}, ...])` ⇒ arity N), so calling
    # `start_link/1` from the supervisor crashes with `:undef`. PR3 tests
    # never exercised that helper. We start the server directly via
    # `PlanningSessionServer.start_link/1` linked to the channel process;
    # the channel owns its session server for the lifetime of its join.
    # When the channel disconnects, the link kills the server (the sweeper
    # will expire any orphaned row). `:lost_lock` transition via the
    # `:DOWN` monitor is not exercised in this path; that requires the
    # supervisor fix tracked as PR5 follow-up.
    membership = socket.assigns.current_membership
    user = socket.assigns.current_user
    account_id = membership.account_id

    with {:ok, date_from} <- parse_iso_date(Map.get(payload, "range_from")),
         {:ok, date_to} <- parse_iso_date(Map.get(payload, "range_to")),
         :ok <- check_account_eligible(account_id) do
      session_id = Ecto.UUID.generate()

      case PlanningSessionServer.start_link(
             account_id: account_id,
             session_id: session_id,
             owner_user_id: user.id,
             owner_membership_id: membership.id
           ) do
        {:ok, pid} ->
          case PlanningSessionServer.start_session(
                 pid,
                 account_id,
                 user.id,
                 membership.id,
                 {date_from, date_to}
               ) do
            {:ok, %{session_id: started_id}} ->
              # `session_started` is broadcast by PlanningSessionServer
              # itself on `planning:<account_id>`. The socket (and any
              # other joined member) receives it as a pubsub broadcast.
              # Do NOT re-broadcast here or the event fires twice.
              #
              # Cache the pid on the socket assigns so `send_message`
              # (PR4 task 4.8) can route intents back to the same server
              # without a Registry lookup.
              socket =
                socket
                |> assign(:session_id, started_id)
                |> assign(:session_pid, pid)

              {:reply, {:ok, %{session_id: started_id, status: :active}}, socket}

            {:error, reason} when is_atom(reason) ->
              {:reply, {:error, %{reason: reason}}, socket}

            {:error, other} ->
              {:reply, {:error, %{reason: serialize_reason(other)}}, socket}
          end

        {:error, reason} when is_atom(reason) ->
          {:reply, {:error, %{reason: reason}}, socket}

        {:error, other} ->
          {:reply, {:error, %{reason: serialize_reason(other)}}, socket}
      end
    else
      {:error, :subscription_required} ->
        {:reply, {:error, %{reason: :subscription_required}}, socket}

      {:error, :invalid_range} ->
        {:reply, {:error, %{reason: :invalid_range}}, socket}
    end
  end

  def handle_in("send_message", payload, socket) do
    # Phase 4 PR4 task 4.8 — channel-layer intake for validated AI
    # intents. The `send_intent` broadcast from `AIChannel.new_message`
    # (task 4.6) is the public notification; THIS handler is the
    # single choke point where the intent is actually applied to the
    # session via `PlanningSessionServer.apply_intent/3`, which runs
    # `validate_ai_intent/1` and returns `{:error, :forbidden_intent}`
    # or `{:error, :unknown_intent}` on rejection.
    #
    # Authorization: the socket must have started a session
    # (`session_pid` cached on the assigns by `start_planning`). A
    # peer who joined but did not start a session gets
    # `:no_active_session`. The `session_id` payload MUST match the
    # cached id — we do NOT apply intents to a different session just
    # because the caller passed a valid UUID.
    case socket.assigns[:session_pid] do
      nil ->
        {:reply, {:error, %{reason: :no_active_session}}, socket}

      session_pid ->
        with {:ok, session_id} <- require_uuid(Map.get(payload, "session_id")),
             {:ok, intent_atom} <- IntentAtomizer.atomize(Map.get(payload, "intent")),
             :ok <- ensure_session_match(session_id, socket.assigns[:session_id]),
             {:ok, validated} <-
               PlanningSessionServer.apply_intent(session_pid, session_id, intent_atom) do
          {:reply, {:ok, validated}, socket}
        else
          {:error, :forbidden_intent} ->
            {:reply, {:error, %{reason: :forbidden_intent}}, socket}

          {:error, :unknown_intent} ->
            {:reply, {:error, %{reason: :unknown_intent}}, socket}

          {:error, :invalid_payload} ->
            {:reply, {:error, %{reason: :invalid_payload}}, socket}

          {:error, :session_mismatch} ->
            {:reply, {:error, %{reason: :session_mismatch}}, socket}

          {:error, :atomize_failed} ->
            {:reply, {:error, %{reason: :invalid_payload}}, socket}
        end
    end
  end

  def handle_in("cancel_planning", payload, socket) do
    # Phase 4 PR4 task 4.4 — owner-scoped cancel.
    #
    # Authorization: the actor must either own the session (matching
    # `lock_owner_membership_id`) OR be the Account's `:owner` role.
    # Anything else (a peer who is not the account owner) gets
    # `:forbidden`. The PR2 `PlanningRepo.cancel_session/4` runs the
    # authorization + status check + child-delete in a single
    # transaction; we just route the call and broadcast the lifecycle
    # event on success.
    membership = socket.assigns.current_membership
    account_id = membership.account_id
    actor_membership_id = membership.id
    account_owner? = membership.role == :owner

    with {:ok, session_id} <- require_uuid(Map.get(payload, "session_id")),
         {:ok, _cancelled} <-
           MealPlannerApi.Data.PlanningRepo.cancel_session(
             account_id,
             session_id,
             actor_membership_id,
             account_owner?
           ) do
      broadcast_session_cancelled(account_id, session_id)

      {:reply, {:ok, %{session_id: session_id, status: :cancelled}}, socket}
    else
      {:error, :forbidden} ->
        {:reply, {:error, %{reason: :forbidden}}, socket}

      {:error, :not_active} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, :invalid_session_id} ->
        {:reply, {:error, %{reason: :invalid_payload}}, socket}
    end
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  defp build_request_id do
    "req_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"

  # Phase 4 PR4 — capability re-check on `start_planning`. Returns
  # `:ok` when the Account is eligible, `{:error, :subscription_required}`
  # otherwise. Mirrors the join-time `ChannelCapability.authorize/1`
  # pattern but with no rollout flag — the channel-layer start guard
  # ALWAYS re-checks, regardless of `:revenuecat_access_enforcement`.
  defp check_account_eligible(account_id) do
    if AccountAccess.eligible?(account_id) do
      :ok
    else
      {:error, :subscription_required}
    end
  end

  # Parses an ISO8601 date string for `start_planning` payloads.
  # Returns `{:ok, Date.t()}` or `{:error, :invalid_range}` on parse fail.
  defp parse_iso_date(string) when is_binary(string) do
    case Date.from_iso8601(string) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_range}
    end
  end

  defp parse_iso_date(_), do: {:error, :invalid_range}

  # Phase 4 PR4 task 4.4 — Validates `session_id` is a UUID string and
  # returns it. Anything else falls back to `{:error, :invalid_session_id}`
  # so the caller can surface a `:invalid_payload` error.
  defp require_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_session_id}
    end
  end

  defp require_uuid(_), do: {:error, :invalid_session_id}

  # Phase 4 PR4 task 4.8 — the caller's `session_id` MUST equal the
  # session cached on the socket assigns. Prevents a caller from
  # applying intents to a session they did not start on this socket.
  defp ensure_session_match(caller_session_id, cached_session_id)
       when caller_session_id == cached_session_id,
       do: :ok

  defp ensure_session_match(_caller, _cached), do: {:error, :session_mismatch}

  defp broadcast_session_cancelled(account_id, session_id) do
    Phoenix.Channel.Server.broadcast!(
      MealPlannerApi.PubSub,
      "planning:#{account_id}",
      "session_cancelled",
      %{"session_id" => session_id}
    )
  end
end
