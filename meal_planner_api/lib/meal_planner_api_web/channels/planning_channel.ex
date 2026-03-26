defmodule MealPlannerApiWeb.PlanningChannel do
  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.PlanningChat

  @impl true
  def join("planning:" <> account_id, _payload, socket) do
    user = socket.assigns.current_user

    if user.account_id == account_id do
      {:ok, assign(socket, :account_id, account_id)}
    else
      {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in("generate_menu", payload, socket) do
    user = socket.assigns.current_user
    request_id = Map.get(payload, "request_id", build_request_id())

    broadcast!(socket, "generation_started", %{request_id: request_id})

    case PlanningChat.generate_menu(user, payload) do
      {:ok, result} ->
        event = %{
          request_id: request_id,
          run_id: result.run.id,
          proposal_id: result.proposal.id,
          date_from: Date.to_iso8601(result.date_from),
          date_to: Date.to_iso8601(result.date_to),
          proposal: result.proposal_json
        }

        broadcast!(socket, "proposal_ready", event)
        {:reply, {:ok, event}, socket}

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

    case PlanningChat.regenerate_menu(user, base_payload, constraints) do
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

  def handle_in("confirm_proposal", %{"proposal_id" => proposal_id}, socket) do
    user = socket.assigns.current_user

    case PlanningChat.confirm_proposal(user, proposal_id) do
      {:ok, result} ->
        event = Map.put(result, :status, "confirmed")
        broadcast!(socket, "proposal_confirmed", event)
        {:reply, {:ok, event}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: serialize_reason(reason)}}, socket}
    end
  end

  def handle_in("reject_proposal", %{"proposal_id" => proposal_id}, socket) do
    user = socket.assigns.current_user

    case PlanningChat.reject_proposal(user, proposal_id) do
      {:ok, result} ->
        event = Map.put(result, :status, "rejected")
        broadcast!(socket, "proposal_rejected", event)
        {:reply, {:ok, event}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: serialize_reason(reason)}}, socket}
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
