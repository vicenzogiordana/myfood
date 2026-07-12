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

  alias MealPlannerApi.Generation.Server
  alias MealPlannerApi.Services.PlanningChatService
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
        {:ok,
         socket
         |> assign(:account_id, topic_account_id)
         |> assign(:current_membership, membership)}
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

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  defp build_request_id do
    "req_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"
end
