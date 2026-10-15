defmodule MealPlannerApi.PlanningAgent.Session do
  @moduledoc """
  The planning agent session module (spec #93): one supervised process per
  active Planning Session, owning the agent loop, the workspace, the limits
  and the consent gate. Its interface is channel-agnostic; the Phoenix
  channel is a thin adapter over it.

  ## Interface

    * `start/2` — opens a Planning Session for a Planning Range of unplanned
      days. One Planning Session per Household: a second start in the same
      Household returns `{:error, :session_already_active}`.
    * `record_consent/1` — the Member's explicit consent to external AI use.
    * `send_message/2` — a Member message; runs one agent turn.
    * `cancel/2` — ends the session (session's Member or Household Owner).
    * `whereis/1` — the active session process of a Household, if any.

  ## Events

  Subscribers receive `{:planning_agent_event, session_id, event}` where
  `event["type"]` is one of `progress`, `assistant_message`, `question`,
  `proposal`, `optimizer_failed`, `consent_required`, `limit_reached`,
  `agent_unavailable`, `turn_completed`, `session_cancelled`, `session_ended`.

  ## Limits

  Per request: `max_iterations` model calls (default 10) and a global
  deadline (default 5 minutes) after which the running turn is killed and
  its late results are discarded.
  """

  use GenServer, restart: :temporary

  require Logger

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.PlanningAgent.{HouseholdContext, Loop}

  @registry MealPlannerApi.PlanningAgent.Registry
  @supervisor MealPlannerApi.PlanningAgent.SessionSupervisor
  @task_supervisor MealPlannerApi.PlanningAgent.TaskSupervisor

  @default_max_iterations 10
  @default_deadline_ms 5 * 60 * 1000
  @lease_seconds 120
  @lease_renew_ms 30_000
  @max_range_days 31
  # Bounds what a Member message adds to the stored transcript, which is
  # re-encoded on every model call.
  @max_message_bytes 4_000
  @known_slots ~w(breakfast lunch snack dinner)

  @type attrs :: %{
          account_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          membership_id: Ecto.UUID.t(),
          role: :owner | :member,
          range: {Date.t(), Date.t()},
          slots: [String.t()]
        }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a Planning Session.

  ## Options

    * `:model` — `{adapter, opts}` implementing `MealPlannerApi.PlanningAgent.Model`
      (default from `config :meal_planner_api, :planning_agent`)
    * `:optimizer` — `{module, opts}` implementing `MealPlannerApi.PlanningAgent.Optimizer`
    * `:subscriber` — pid receiving events (more can join with `subscribe/2`)
    * `:max_iterations`, `:deadline_ms` — per-request limits
  """
  @spec start(attrs(), keyword()) ::
          {:ok, %{session_id: Ecto.UUID.t(), pid: pid()}}
          | {:error,
             :invalid_range
             | :invalid_slots
             | :range_already_planned
             | :session_already_active
             | term()}
  def start(attrs, opts \\ []) do
    {model, model_opts} = Keyword.get_lazy(opts, :model, fn -> config(:model) end)

    with {:ok, {from_date, to_date}} <- validate_range(attrs.range),
         :ok <- validate_slots(attrs.slots),
         :ok <- ensure_unplanned(attrs.account_id, from_date, to_date),
         {:ok, model_state} <- model.init(model_opts),
         {:ok, row} <- lock(attrs, from_date, to_date) do
      init_args = %{
        attrs: attrs,
        session_id: row.id,
        model: model,
        model_state: model_state,
        optimizer: Keyword.get_lazy(opts, :optimizer, fn -> config(:optimizer) end),
        subscriber: Keyword.get(opts, :subscriber),
        max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
        deadline_ms: Keyword.get(opts, :deadline_ms, @default_deadline_ms)
      }

      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, init_args}) do
        {:ok, pid} ->
          {:ok, %{session_id: row.id, pid: pid}}

        {:error, reason} ->
          _ = PlanningRepo.expire_session(attrs.account_id, row.id)
          {:error, reason}
      end
    end
  end

  @doc false
  def start_link(init_args), do: GenServer.start_link(__MODULE__, init_args)

  @doc "Records the session Member's consent to external AI processing."
  @spec record_consent(GenServer.server()) :: :ok | {:error, term()}
  def record_consent(session), do: GenServer.call(session, :record_consent)

  @doc """
  Sends a Member message and starts one agent turn. Refuses with
  `:consent_required` (no model call) until consent is recorded, and with
  `:busy` while a turn is running. A text over `max_message_bytes/0` is
  refused with `:message_too_long` and never stored.
  """
  @spec send_message(GenServer.server(), String.t()) ::
          :ok | {:error, :consent_required | :busy | :invalid_message | :message_too_long}
  def send_message(session, text), do: GenServer.call(session, {:send_message, text})

  @doc "The largest Member message, in bytes, a session accepts."
  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message_bytes

  @doc "Adds an event subscriber."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(session, pid), do: GenServer.call(session, {:subscribe, pid})

  @doc """
  Cancels the session, discarding its workspace and releasing the
  Household's slot. Allowed for the session's Member and the Owner.
  """
  @spec cancel(GenServer.server(), %{membership_id: Ecto.UUID.t(), owner?: boolean()}) ::
          :ok | {:error, :forbidden}
  def cancel(session, actor), do: GenServer.call(session, {:cancel, actor})

  @doc "Returns the session id and owning membership of a running session."
  @spec info(GenServer.server()) :: %{session_id: Ecto.UUID.t(), membership_id: Ecto.UUID.t()}
  def info(session), do: GenServer.call(session, :info)

  @doc "The running session process of a Household, or `nil`."
  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(account_id) do
    case Registry.lookup(@registry, {:household, account_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # ===========================================================================
  # GenServer
  # ===========================================================================

  @impl true
  def init(args) do
    # Trap exits so a supervisor or application shutdown runs terminate/2,
    # which releases the Household lock instead of waiting for the lease to
    # lapse. Turns run under async_nolink, so no turn exit reaches here.
    Process.flag(:trap_exit, true)
    %{attrs: attrs} = args
    {:ok, _} = Registry.register(@registry, {:household, attrs.account_id}, args.session_id)

    household = HouseholdContext.load(attrs.account_id, attrs.user_id)

    state = %{
      session_id: args.session_id,
      account_id: attrs.account_id,
      user_id: attrs.user_id,
      membership_id: attrs.membership_id,
      range: attrs.range,
      slots: attrs.slots,
      household: household,
      consent?: household.consent?,
      instructions: HouseholdContext.instructions(household, attrs.range, attrs.slots),
      model: args.model,
      model_state: args.model_state,
      optimizer: args.optimizer,
      messages: [],
      workspace: %{draft: nil, proposal: nil},
      subscribers: %{},
      task: nil,
      deadline_ref: nil,
      max_iterations: args.max_iterations,
      deadline_ms: args.deadline_ms
    }

    state = if args.subscriber, do: add_subscriber(state, args.subscriber), else: state
    schedule_lease_renewal()
    {:ok, state}
  end

  @impl true
  def handle_call(:record_consent, _from, state) do
    case MealPlannerApi.PlanningAgent.Consent.record(state.account_id, state.user_id) do
      :ok -> {:reply, :ok, %{state | consent?: true}}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:send_message, text}, _from, state) do
    cond do
      not is_binary(text) or String.trim(text) == "" ->
        {:reply, {:error, :invalid_message}, state}

      byte_size(text) > @max_message_bytes ->
        {:reply, {:error, :message_too_long}, state}

      not state.consent? ->
        emit(state, %{"type" => "consent_required"})
        {:reply, {:error, :consent_required}, state}

      state.task != nil ->
        {:reply, {:error, :busy}, state}

      true ->
        state = %{state | messages: state.messages ++ [%{role: :user, content: text}]}
        {:reply, :ok, start_turn(state)}
    end
  end

  def handle_call({:subscribe, pid}, _from, state), do: {:reply, :ok, add_subscriber(state, pid)}

  def handle_call(:info, _from, state),
    do: {:reply, %{session_id: state.session_id, membership_id: state.membership_id}, state}

  def handle_call({:cancel, %{membership_id: actor, owner?: owner?}}, _from, state) do
    if actor == state.membership_id or owner? == true do
      state = stop_turn(state)

      # When the store refuses the cancel, session_id is kept so terminate/2
      # falls back to expire_session and the Household is not left blocked
      # until the lease lapses.
      session_id =
        case PlanningRepo.cancel_session(state.account_id, state.session_id, actor, owner?) do
          {:ok, _} ->
            nil

          {:error, reason} ->
            Logger.warning("planning agent cancel: #{inspect(reason)}")
            state.session_id
        end

      emit(state, %{"type" => "session_cancelled"})
      {:stop, :normal, :ok, %{state | session_id: session_id}}
    else
      {:reply, {:error, :forbidden}, state}
    end
  end

  @impl true
  def handle_info({:agent_event, ref, event}, %{task: %Task{ref: ref}} = state) do
    emit(state, event)
    {:noreply, state}
  end

  # Events of a killed turn arrive late: they are discarded.
  def handle_info({:agent_event, _stale_ref, _event}, state), do: {:noreply, state}

  # Model state checkpoints carry paid usage (spend ledger), so the session
  # keeps it even when the turn is later killed or crashes.
  def handle_info({:model_state, ref, model_state}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | model_state: model_state}}

  def handle_info({:model_state, _stale_ref, _model_state}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state = %{
      clear_turn(state)
      | model_state: result.model_state,
        messages: result.messages,
        workspace: result.workspace
    }

    if result.outcome == :completed, do: emit(state, %{"type" => "turn_completed"})
    {:noreply, state}
  end

  def handle_info({:deadline, ref}, %{task: %Task{ref: ref}} = state) do
    state = stop_turn(state)
    emit(state, %{"type" => "limit_reached", "limit" => "time"})
    {:noreply, state}
  end

  def handle_info({:deadline, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("planning agent turn crashed: #{inspect(reason)}")
    state = clear_turn(state)
    emit(state, %{"type" => "agent_unavailable", "reason" => "internal_error"})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.subscribers, pid) do
      {^ref, subscribers} when map_size(subscribers) == 0 ->
        # Grace and recovery belong to a later slice of #93: for now the
        # Planning Session ends when its last subscriber is gone.
        {:stop, :normal, %{state | subscribers: subscribers}}

      {_, subscribers} ->
        {:noreply, %{state | subscribers: subscribers}}
    end
  end

  def handle_info(:renew_lease, state) do
    until = DateTime.add(DateTime.utc_now(), @lease_seconds, :second)

    case PlanningRepo.renew_lease(state.account_id, state.session_id, until) do
      :ok ->
        schedule_lease_renewal()
        {:noreply, state}

      # The lock row was expired behind this session's back (e.g. the Sweeper
      # after a lapsed lease): the Household may already belong to a new
      # session, so stop spending now. session_id is cleared so terminate/2
      # does not expire the row a second time.
      {:error, :not_active} ->
        Logger.warning("planning agent session lost its lock; stopping")
        state = stop_turn(state)
        emit(state, %{"type" => "session_ended"})
        {:stop, :normal, %{state | session_id: nil}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = stop_turn(state)

    if state.session_id do
      _ = PlanningRepo.expire_session(state.account_id, state.session_id)
      emit(state, %{"type" => "session_ended"})
    end

    :ok
  end

  # ===========================================================================
  # Turn management
  # ===========================================================================

  defp start_turn(state) do
    session = self()
    holder = make_ref()

    turn = %{
      model: state.model,
      model_state: state.model_state,
      instructions: state.instructions,
      messages: state.messages,
      max_iterations: state.max_iterations,
      tool_context: %{
        account_id: state.account_id,
        session_id: state.session_id,
        range: state.range,
        slots: state.slots,
        household: state.household,
        optimizer: state.optimizer,
        workspace: state.workspace
      }
    }

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        ref = receive(do: ({^holder, ref} -> ref))
        emit_fun = fn event -> send(session, {:agent_event, ref, event}) end
        checkpoint = fn model_state -> send(session, {:model_state, ref, model_state}) end
        tool_context = Map.put(turn.tool_context, :emit, emit_fun)

        %{turn | tool_context: tool_context}
        |> Map.put(:emit, emit_fun)
        |> Map.put(:checkpoint, checkpoint)
        |> Loop.run()
      end)

    send(task.pid, {holder, task.ref})
    deadline_ref = Process.send_after(self(), {:deadline, task.ref}, state.deadline_ms)
    %{state | task: task, deadline_ref: deadline_ref}
  end

  defp stop_turn(%{task: nil} = state), do: state

  defp stop_turn(%{task: task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    # The task is dead, so every checkpoint it sent is already queued: adopt
    # the latest one so the killed turn's paid usage stays counted.
    clear_turn(%{state | model_state: latest_checkpoint(task.ref, state.model_state)})
  end

  defp latest_checkpoint(ref, model_state) do
    receive do
      {:model_state, ^ref, newer} -> latest_checkpoint(ref, newer)
    after
      0 -> model_state
    end
  end

  defp clear_turn(state) do
    if state.deadline_ref, do: Process.cancel_timer(state.deadline_ref)
    %{state | task: nil, deadline_ref: nil}
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp add_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid) do
      state
    else
      %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
    end
  end

  defp emit(state, event) do
    Enum.each(Map.keys(state.subscribers), fn pid ->
      send(pid, {:planning_agent_event, state.session_id, event})
    end)
  end

  defp schedule_lease_renewal, do: Process.send_after(self(), :renew_lease, @lease_renew_ms)

  defp validate_range({%Date{} = from_date, %Date{} = to_date}) do
    days = Date.diff(to_date, from_date) + 1

    if days >= 1 and days <= @max_range_days,
      do: {:ok, {from_date, to_date}},
      else: {:error, :invalid_range}
  end

  defp validate_range(_), do: {:error, :invalid_range}

  defp validate_slots([_ | _] = slots) do
    if Enum.all?(slots, &(&1 in @known_slots)) and Enum.uniq(slots) == slots,
      do: :ok,
      else: {:error, :invalid_slots}
  end

  defp validate_slots(_), do: {:error, :invalid_slots}

  defp ensure_unplanned(account_id, from_date, to_date) do
    if PlanningRepo.range_planned?(account_id, from_date, to_date),
      do: {:error, :range_already_planned},
      else: :ok
  end

  defp lock(attrs, from_date, to_date) do
    PlanningRepo.create_household_session(attrs.account_id, %{
      range_from: from_date,
      range_to: to_date,
      lock_owner_user_id: attrs.user_id,
      lock_owner_membership_id: attrs.membership_id,
      lease_expires_at: DateTime.add(DateTime.utc_now(), @lease_seconds, :second)
    })
  end

  defp config(key) do
    :meal_planner_api
    |> Application.get_env(:planning_agent, [])
    |> Keyword.get(key)
  end
end
