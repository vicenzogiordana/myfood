defmodule MealPlannerApiWeb.AIChannel do
  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.AI
  alias MealPlannerApi.Services.GenerationService
  alias MealPlannerApiWeb.ChannelCapability
  alias MealPlannerApiWeb.Channels.IntentAtomizer
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers
  alias MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket

  # Note (task 3.12): unlike planning/cooking/calendar, this channel's topic
  # is `ai_chat:<room_id>` — an opaque chat/session identifier, NOT
  # `ai:<account_id>`. There is no account_id embedded in the topic to
  # cross-check against current_membership.account_id, so join/3 enforces
  # "the socket carries an active membership" (nil/non-active rejected)
  # rather than a topic-vs-membership account match. See apply-progress.md
  # for the full deviation writeup.
  #
  # Note (task 4.2 / Phase 4): after the membership/status check, the
  # shared `ChannelCapability.authorize/1` guard fires off the
  # membership's `account_id` (NOT the topic) so an expired Account is
  # rejected with `subscription_required` whenever the rollout flag is on.
  @impl true
  def join("ai_chat:" <> room_id, _payload, socket) do
    membership = LoadCurrentMembershipSocket.membership_from_socket(socket)

    cond do
      is_nil(membership) ->
        {:error, %{reason: "forbidden"}}

      membership.status != :active ->
        {:error, %{reason: "forbidden"}}

      true ->
        case ChannelCapability.authorize(membership) do
          :ok ->
            {:ok,
             socket
             |> assign(:room_id, room_id)
             |> assign(:current_membership, membership)}

          {:error, :subscription_required} ->
            {:error, %{reason: "subscription_required"}}
        end
    end
  end

  @impl true
  def handle_in("new_message", %{"message" => message} = payload, socket)
      when is_binary(message) do
    membership = socket.assigns.current_membership

    # Post-PR-3c review — BLOCKER fix: bring AIChannel into the same
    # "single choke point" pattern as the 7 controllers + AccountsController
    # (tasks 3.14-3.22) — the User struct's `:account_id` must be
    # corrected to `current_membership.account_id` (DB-resolved via
    # `membership_id`) before it reaches any service, never trust the
    # claim-derived `current_user.account_id` (see AccountScopeHelpers.
    # scope_user_to_membership/2 moduledoc for the full rationale).
    user =
      AccountScopeHelpers.scope_user_to_membership(socket.assigns.current_user, membership)

    request_id = Map.get(payload, "request_id", build_request_id())

    # Phase 4 PR4 task 4.6 — typed-intent boundary lives here. If the
    # payload carries an `intent`, atomize it (JSON → Elixir map),
    # validate it against `validate_ai_intent/1`, and on success
    # broadcast `send_intent` on `planning:<account_id>` so any
    # joined planning session picks it up. On validation failure
    # we short-circuit: the AI stream does NOT start and the
    # caller gets the matching atom reason. A missing or
    # non-map intent is treated as "no intent supplied" — the AI
    # stream still runs (backward compat for plain text messages).
    with :ok <- maybe_validate_intent(Map.get(payload, "intent")) do
      broadcast_validated_intent(membership.account_id, Map.get(payload, "intent"))

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
    else
      {:error, :forbidden_intent} ->
        push(socket, "ai_response_error", %{
          request_id: request_id,
          account_id: membership.account_id,
          error: "forbidden_intent"
        })

        {:reply, {:error, %{reason: :forbidden_intent}}, socket}

      {:error, :unknown_intent} ->
        push(socket, "ai_response_error", %{
          request_id: request_id,
          account_id: membership.account_id,
          error: "unknown_intent"
        })

        {:reply, {:error, %{reason: :unknown_intent}}, socket}

      {:error, :invalid_payload} ->
        {:reply, {:error, %{reason: :invalid_payload}}, socket}
    end
  end

  def handle_in("new_message", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  # No intent supplied → stream runs without forwarding anything.
  defp maybe_validate_intent(nil), do: :ok

  defp maybe_validate_intent(%{} = intent) do
    with {:ok, atom_intent} <- IntentAtomizer.atomize(intent) do
      case GenerationService.validate_ai_intent(atom_intent) do
        {:ok, _validated} -> :ok
        {:error, _} = err -> err
      end
    else
      :error -> {:error, :invalid_payload}
    end
  end

  defp maybe_validate_intent(_), do: {:error, :invalid_payload}

  # Broadcast the validated intent on the planning topic. The
  # `PlanningSessionServer` (PR3) does not subscribe here directly
  # — `PlanningChannel.send_message/2` (PR4 task 4.8) is the
  # actual choke point. The broadcast is the public notification
  # that an AI-emitted intent is ready to be applied; clients
  # drive the application via `send_message`.
  defp broadcast_validated_intent(_account_id, nil), do: :ok

  defp broadcast_validated_intent(account_id, %{} = intent) do
    case IntentAtomizer.atomize(intent) do
      {:ok, atom_intent} ->
        Phoenix.Channel.Server.broadcast!(
          MealPlannerApi.PubSub,
          "planning:#{account_id}",
          "send_intent",
          %{"intent" => atom_intent}
        )

      _ ->
        :ok
    end
  end

  defp build_request_id do
    "req_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
