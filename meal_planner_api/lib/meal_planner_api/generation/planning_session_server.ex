defmodule MealPlannerApi.Generation.PlanningSessionServer do
  @moduledoc """
  Per-session lifecycle GenServer for the `ephemeral-planning-sessions`
  change.

  One process per active `PlanningSession`, supervised under
  `MealPlannerApi.Generation.PlanningSessionSupervisor`. Each session
  owns the (account, range) lock enforced by the Postgres partial
  EXCLUDE constraint; the GenServer mirrors that ownership in-memory
  and broadcasts state transitions on `planning:<account_id>` via
  `Phoenix.Channel.Server.broadcast!/4`.

  ## Lifecycle

      :initializing  ──start_session──►  :active
      :active        ──cancel_session──►  :cancelled
      :active        ──mark_committed──►  :committed
      :active        ──:DOWN abnormal──►  :lost_lock
      :active        ──sweeper─────────►  :expired     (DB-side, not this GS)

  ## Authorization

  Entitlement is re-checked at `start_session/5` via the injectable
  `:check_account_eligible_fn` opt (default `&AccountAccess.eligible?/1`).
  Cancellation / commit delegate to `PlanningRepo` which already
  enforces per-(account, actor) authorization.

  ## :DOWN semantics

  Only abnormal exit reasons (anything other than `:normal`,
  `:shutdown`, `{:shutdown, _}`) trigger the `:lost_lock` transition.
  This matches the design's "owner crash → :lost_lock" semantics while
  keeping clean supervisor restarts / clean channel disconnects
  noise-free.
  """

  use GenServer, restart: :temporary

  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Planning.PlanningSession

  @lease_seconds 120

  @type state :: %{
          account_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t(),
          status: :initializing | :active | :cancelled | :committed | :lost_lock | :expired,
          owner_user_id: pos_integer() | nil,
          owner_membership_id: Ecto.UUID.t() | nil,
          lease_ref: reference() | nil,
          monitor_ref: reference() | nil,
          pending_intent: map() | nil,
          check_account_eligible_fn: (term() -> boolean())
        }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a session process under a supervisor. Used as a child spec.

  ## Required opt

    * `:account_id` — the Account whose planning topic the server
      broadcasts on.

  ## Optional opts

    * `:session_id` — UUID for the process's in-memory identity
      (default: `Ecto.UUID.generate/0`). The canonical row id comes
      from `PlanningRepo.create_session/2` once the row is inserted.
    * `:owner_user_id` — informational; copied onto the row.
    * `:owner_membership_id` — informational; copied onto the row.
    * `:check_account_eligible_fn` — defaults to
      `&AccountAccess.eligible?/1`. Override in tests to force
      `:subscription_required`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    account_id = Keyword.fetch!(opts, :account_id)

    initial_state = %{
      account_id: account_id,
      session_id: Keyword.get(opts, :session_id, Ecto.UUID.generate()),
      status: :initializing,
      owner_user_id: Keyword.get(opts, :owner_user_id),
      owner_membership_id: Keyword.get(opts, :owner_membership_id),
      lease_ref: nil,
      monitor_ref: nil,
      pending_intent: nil,
      check_account_eligible_fn:
        Keyword.get(opts, :check_account_eligible_fn, &AccountAccess.eligible?/1)
    }

    GenServer.start_link(__MODULE__, initial_state)
  end

  @doc """
  Registers a `:active` planning-sessions row for the given range.

  The entitlement check runs first; on `:false` the call returns
  `{:error, :subscription_required}` without writing a row. On an
  overlapping active range the Postgres EXCLUDE constraint rejects
  the insert and the server replies `{:error, :overlapping_range}`.
  Both failure modes leave the server's state as `:initializing` —
  the row never lands.
  """
  @spec start_session(
          GenServer.server(),
          Ecto.UUID.t(),
          pos_integer(),
          Ecto.UUID.t(),
          {Date.t(), Date.t()}
        ) ::
          {:ok, %{session_id: Ecto.UUID.t()}}
          | {:error, :subscription_required | :overlapping_range | :already_active | term()}
  def start_session(server, account_id, user_id, membership_id, {date_from, date_to}) do
    GenServer.call(
      server,
      {:start_session, account_id, user_id, membership_id, {date_from, date_to}}
    )
  end

  @doc """
  Cancels the named session.

  The 4th-arg `account_owner?` mirrors the authorization contract from
  `PlanningRepo.cancel_session/4` — owner membership or account `:owner`
  may cancel; peers get `:forbidden`. On success, broadcasts
  `session_cancelled` on `planning:<account_id>`.
  """
  @spec cancel_session(
          GenServer.server(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          boolean()
        ) ::
          :ok | {:error, :forbidden | :not_active}
  def cancel_session(server, account_id, session_id, actor_membership_id, account_owner?)
      when is_boolean(account_owner?) do
    GenServer.call(
      server,
      {:cancel_session, account_id, session_id, actor_membership_id, account_owner?}
    )
  end

  @doc """
  Validates an AI-emitted intent against the typed-intent boundary
  (`GenerationService.validate_ai_intent/1`) and, on `:ok`, stores the
  validated intent in state for PR4's channel handler to consume.

  Returns the same shape as `GenerationService.validate_ai_intent/1`.
  """
  @spec apply_intent(GenServer.server(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, :forbidden_intent | :unknown_intent}
  def apply_intent(server, session_id, intent) when is_map(intent) do
    GenServer.call(server, {:apply_intent, session_id, intent})
  end

  @doc """
  Transitions the session to `:committed`. On success, broadcasts
  `session_committed` on `planning:<account_id>`. Does NOT hard-delete
  children — `:committed` is an audit-friendly terminal status.
  """
  @spec mark_committed(GenServer.server(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :not_active}
  def mark_committed(server, account_id, session_id) do
    GenServer.call(server, {:mark_committed, account_id, session_id})
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(
        {:start_session, account_id, user_id, membership_id, {date_from, date_to}},
        _from,
        state
      ) do
    cond do
      state.status == :active ->
        {:reply, {:error, :already_active}, state}

      not state.check_account_eligible_fn.(account_id) ->
        {:reply, {:error, :subscription_required}, state}

      true ->
        lease = DateTime.add(DateTime.utc_now(), @lease_seconds, :second)

        attrs = %{
          range_from: date_from,
          range_to: date_to,
          lock_owner_user_id: user_id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: lease
        }

        case PlanningRepo.create_session(account_id, attrs) do
          {:ok, %PlanningSession{id: session_id} = _session} ->
            new_state = %{state | session_id: session_id, status: :active}

            broadcast(account_id, "session_started", %{"session_id" => session_id})

            {:reply, {:ok, %{session_id: session_id}}, new_state}

          {:error, :overlapping_range} ->
            {:reply, {:error, :overlapping_range}, state}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:reply, {:error, changeset}, state}

          {:error, other} ->
            {:reply, {:error, other}, state}
        end
    end
  end

  @impl true
  def handle_call(
        {:cancel_session, account_id, session_id, actor_membership_id, account_owner?},
        _from,
        state
      ) do
    case PlanningRepo.cancel_session(account_id, session_id, actor_membership_id, account_owner?) do
      {:ok, _cancelled} ->
        broadcast(account_id, "session_cancelled", %{"session_id" => session_id})
        new_state = %{state | status: :cancelled}
        {:reply, :ok, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:apply_intent, _session_id, intent}, _from, state) do
    case MealPlannerApi.Services.GenerationService.validate_ai_intent(intent) do
      {:ok, validated} ->
        new_state = %{state | pending_intent: validated}
        {:reply, {:ok, validated}, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:mark_committed, account_id, session_id}, _from, state) do
    case PlanningRepo.mark_committed(account_id, session_id) do
      {:ok, _committed} ->
        broadcast(account_id, "session_committed", %{"session_id" => session_id})
        new_state = %{state | status: :committed}
        {:reply, :ok, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    case reason do
      reason when reason in [:normal, :shutdown] ->
        # Clean exits do NOT trigger lost_lock — the channel disconnected
        # intentionally, or the supervisor shut us down cleanly. Stay
        # silent on the broadcast topic.
        {:noreply, state}

      {:shutdown, _} ->
        {:noreply, state}

      _ ->
        # Abnormal exit — owner crashed. Transition row + broadcast.
        if state.status == :active do
          case PlanningRepo.mark_lost_lock(state.account_id, state.session_id) do
            {:ok, _lost} ->
              broadcast(
                state.account_id,
                "session_lost_lock",
                %{"session_id" => state.session_id}
              )

              {:noreply, %{state | status: :lost_lock}}

            {:error, _} ->
              {:noreply, state}
          end
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp broadcast(account_id, event, payload) do
    Phoenix.Channel.Server.broadcast!(
      MealPlannerApi.PubSub,
      "planning:#{account_id}",
      event,
      payload
    )
  end
end
