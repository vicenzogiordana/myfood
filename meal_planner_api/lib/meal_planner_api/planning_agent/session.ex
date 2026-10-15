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
    * `authorize_continuation/2` — the session Member's explicit
      authorization to continue after a limit was reached.
    * `cancel/2` — ends the session (session's Member or Household Owner).
    * `confirm/3` — the session Member's confirmation of the exact displayed
      Proposal: saves its Planned Meals and appends its Purchase to the
      Shopping List (see "Confirmation").
    * `confirmation_status/2` — the status of a confirmation, queryable after
      the Planning Session ended.
    * `whereis/1` — the active session process of a Household, if any.

  ## Events

  Subscribers receive `{:planning_agent_event, session_id, event}` where
  `event["type"]` is one of `progress`, `assistant_message`, `question`,
  `proposal`, `optimizer_failed`, `consent_required`, `limit_reached`,
  `agent_unavailable`, `turn_completed`, `run_finished`, `session_cancelled`,
  `session_ended`, `proposal_confirmed`, `proposal_invalidated`,
  `confirmation_unresolved`.

  Every run (one request, or one authorized continuation) ends with exactly
  one `run_finished` event whose `outcome` is `complete`, `partial` (stopped
  by a limit), `failure`, `cancelled` or `unknown` (the turn crashed). Every
  tool result carries its own outcome kind (see `MealPlannerApi.PlanningAgent.Tools`).

  Streaming carries progress only: every event passes an allowlist of types
  and fields before it is sent, so raw tool output, tool arguments and model
  reasoning never reach subscribers.

  ## Limits

    * `max_iterations` agent iterations (model calls, default 10) per
      Planning Session; a new Member message does not reset them
    * 3 consecutive attempts without verifiable progress
      (see `MealPlannerApi.PlanningAgent.Allowance`)
    * a global deadline per request (default 5 minutes) after which the
      running turn is killed and its late results are discarded
    * per-call deadlines and retry budgets
      (see `MealPlannerApi.PlanningAgent.CallBounds`)

  Reaching any of the first three stops the run and emits `limit_reached`
  with `"requires_authorization" => true`. From then on `send_message/2`
  refuses with `:authorization_required` until the session's Member calls
  `authorize_continuation/2`, which extends only the reached limit and
  resumes the request. Counters never reset on their own. The spend and
  token caps of the model adapter are per Planning Session as well and are
  never extended by an authorization.

  ## Confirmation

  Only the Member's confirmation saves a plan; no agent tool can. It names
  the exact displayed Proposal by its `proposal_id`, which is also the
  confirmation identity (`MealPlannerApi.PlanningAgent.Confirmation`). The
  Planning Session then ends as committed and releases the Household's slot.
  A replay of the same confirmation returns the original result, even after
  the session ended, and never saves twice.
  """

  use GenServer, restart: :temporary

  require Logger

  alias MealPlannerApi.Data.PlanningRepo

  alias MealPlannerApi.PlanningAgent.{
    Allowance,
    CallBounds,
    Confirmation,
    HouseholdContext,
    Loop,
    Proposal,
    ProposalValidator
  }

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
  # A confirmation may reconcile a lost acknowledgement for up to 30 s.
  @confirm_call_timeout 60_000

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
    * `:max_iterations`, `:deadline_ms` — execution limits
    * `:call_policies` — per-kind overrides of the per-call deadlines and
      retry budgets (see `MealPlannerApi.PlanningAgent.CallBounds`)
    * `:recipe_search` — `{module, opts}` replacing the recipe search read
      tool (`module.search(household, filters, opts)`), for tests
    * `:confirmation_store` — `{module, opts}` replacing the confirmation
      store (see `MealPlannerApi.PlanningAgent.Confirmation`), for tests
    * `:reconcile_ms`, `:poll_ms` — how long and how often a lost
      confirmation acknowledgement is reconciled (default 30 s and 1 s)
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
        model_state: seal(model_state),
        optimizer: Keyword.get_lazy(opts, :optimizer, fn -> config(:optimizer) end),
        subscriber: Keyword.get(opts, :subscriber),
        max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
        deadline_ms: Keyword.get(opts, :deadline_ms, @default_deadline_ms),
        call_policies: Keyword.get(opts, :call_policies, %{}),
        recipe_search: Keyword.get(opts, :recipe_search),
        confirmation_store: Keyword.get_lazy(opts, :confirmation_store, &Confirmation.store/0),
        confirmation_opts: Keyword.take(opts, [:reconcile_ms, :poll_ms])
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
          :ok
          | {:error,
             :consent_required
             | :busy
             | :invalid_message
             | :message_too_long
             | :authorization_required}
  def send_message(session, text), do: GenServer.call(session, {:send_message, text})

  @doc """
  The session Member's explicit authorization to continue after a limit was
  reached: extends that limit only and resumes the request. Refuses with
  `:forbidden` for anyone else (the Owner included) and with
  `:no_limit_reached` when no limit is pending.
  """
  @spec authorize_continuation(GenServer.server(), Ecto.UUID.t()) ::
          :ok | {:error, :forbidden | :no_limit_reached}
  def authorize_continuation(session, membership_id),
    do: GenServer.call(session, {:authorize_continuation, membership_id})

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

  @doc """
  The session Member's confirmation of the Proposal `proposal_id` in the
  Household `account_id`.

  Returns `{:ok, summary}` when the confirmation is saved, or was already
  saved (a replay, also after the Planning Session ended). Otherwise
  nothing is saved:

    * `:forbidden` — not the session's Member
    * `:busy` — the agent is working; the shown Proposal may be replaced
    * `:stale_proposal` — not the current Proposal; the Member is shown it
      again
    * `:session_not_active` — the Planning Session ended meanwhile

  `:unresolved` means the outcome could not be verified within the
  reconciliation window; it is never a failure, and
  `confirmation_status/2` reports the outcome once readable.
  """
  @spec confirm(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Confirmation.summary()}
          | {:error,
             :forbidden
             | :busy
             | :stale_proposal
             | :session_not_active
             | :unresolved
             | term()}
  def confirm(account_id, membership_id, proposal_id) do
    case whereis(account_id) do
      nil ->
        replayed(account_id, proposal_id)

      pid ->
        try do
          GenServer.call(pid, {:confirm, membership_id, proposal_id}, @confirm_call_timeout)
        catch
          # The session ended meanwhile, for instance after this very
          # confirmation committed.
          :exit, {reason, _} when reason in [:noproc, :normal] ->
            replayed(account_id, proposal_id)
        end
    end
  end

  @doc """
  The status of the confirmation `proposal_id` in the Household:
  `{:confirmed, summary}`, `:not_found`, or `:unknown` while it cannot be read.
  """
  @spec confirmation_status(Ecto.UUID.t(), String.t()) ::
          {:confirmed, Confirmation.summary()} | :not_found | :unknown
  def confirmation_status(account_id, proposal_id),
    do: Confirmation.lookup(Confirmation.store(), account_id, proposal_id)

  defp replayed(account_id, proposal_id) do
    case confirmation_status(account_id, proposal_id) do
      {:confirmed, summary} -> {:ok, summary}
      :not_found -> {:error, :stale_proposal}
      :unknown -> {:error, :unresolved}
    end
  end

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
      allowance: Allowance.new(args.max_iterations),
      pending_limit: nil,
      deadline_ms: args.deadline_ms,
      call_policies: CallBounds.policies(args.call_policies),
      recipe_search: args.recipe_search,
      confirmation_store: args.confirmation_store,
      confirmation_opts: args.confirmation_opts,
      # Read by the running turn without a message round trip: no retry
      # starts while no Member is connected.
      presence: :atomics.new(1, [])
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

      state.pending_limit != nil ->
        {:reply, {:error, :authorization_required}, state}

      true ->
        state = %{state | messages: state.messages ++ [%{role: :user, content: text}]}
        {:reply, :ok, start_turn(state)}
    end
  end

  def handle_call({:authorize_continuation, membership_id}, _from, state) do
    cond do
      membership_id != state.membership_id ->
        {:reply, {:error, :forbidden}, state}

      state.pending_limit == nil ->
        {:reply, {:error, :no_limit_reached}, state}

      true ->
        allowance = Allowance.authorize(state.allowance, state.pending_limit)
        state = %{state | allowance: allowance, pending_limit: nil}
        {:reply, :ok, start_turn(state)}
    end
  end

  def handle_call({:subscribe, pid}, _from, state), do: {:reply, :ok, add_subscriber(state, pid)}

  def handle_call(:info, _from, state),
    do: {:reply, %{session_id: state.session_id, membership_id: state.membership_id}, state}

  def handle_call({:cancel, %{membership_id: actor, owner?: owner?}}, _from, state) do
    if actor == state.membership_id or owner? == true do
      state = cancel_run(state)

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

  def handle_call({:confirm, membership_id, _proposal_id}, _from, state)
      when membership_id != state.membership_id,
      do: {:reply, {:error, :forbidden}, state}

  def handle_call({:confirm, _membership_id, proposal_id}, _from, state) do
    case Confirmation.lookup(state.confirmation_store, state.account_id, proposal_id) do
      {:confirmed, summary} -> confirmed(state, proposal_id, summary)
      _not_confirmed -> confirm_current(state, proposal_id)
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
  def handle_info({:model_state, ref, sealed}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | model_state: sealed}}

  def handle_info({:model_state, _stale_ref, _model_state}, state), do: {:noreply, state}

  # Allowance checkpoints keep counted iterations of a turn that is killed.
  def handle_info({:allowance, ref, allowance}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | allowance: allowance}}

  def handle_info({:allowance, _stale_ref, _allowance}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state = %{
      clear_turn(state)
      | model_state: result.model_state,
        messages: result.messages,
        workspace: result.workspace,
        allowance: result.allowance
    }

    {:noreply, finish_run(state, result.outcome)}
  end

  def handle_info({:deadline, ref}, %{task: %Task{ref: ref}} = state) do
    state = stop_turn(state)
    {:noreply, finish_run(state, {:limit_reached, "time"})}
  end

  def handle_info({:deadline, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("planning agent turn crashed: #{inspect(reason)}")
    state = clear_turn(state)
    emit(state, %{"type" => "agent_unavailable", "reason" => "internal_error"})
    emit(state, %{"type" => "run_finished", "outcome" => "unknown"})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.subscribers, pid) do
      {^ref, subscribers} when map_size(subscribers) == 0 ->
        :atomics.put(state.presence, 1, 0)

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
        state = cancel_run(state)
        emit(state, %{"type" => "session_ended"})
        {:stop, :normal, %{state | session_id: nil}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_run(state)

    if state.session_id do
      _ = PlanningRepo.expire_session(state.account_id, state.session_id)
      emit(state, %{"type" => "session_ended"})
    end

    :ok
  end

  # The Household chat is reduced to its length and a Member message to a
  # marker wherever OTP prints this callback's result (`:sys.get_status/1`
  # and crash reports). The model state, which holds the provider API key,
  # is sealed instead (see `seal/1`): OTP 29 appends the raw stacktrace,
  # whose top frame can carry the state, outside this callback.
  @impl true
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &redact_state/1)
    |> Map.replace_lazy(:message, &redact_message/1)
  end

  defp redact_state(%{messages: messages} = state),
    do: %{state | messages: {:redacted, length(messages)}}

  defp redact_state(state), do: state

  defp redact_message({:send_message, _text}), do: {:send_message, :redacted}
  defp redact_message(message), do: message

  # ===========================================================================
  # Confirmation
  # ===========================================================================

  defp confirm_current(%{task: %Task{}} = state, _proposal_id),
    do: {:reply, {:error, :busy}, state}

  defp confirm_current(%{workspace: %{proposal: %{"proposal_id" => id} = shown}} = state, id) do
    commit(state, shown)
  end

  # Not the Proposal on display: the Member is shown the current one again.
  defp confirm_current(state, _proposal_id) do
    if state.workspace.proposal, do: emit(state, state.workspace.proposal)
    {:reply, {:error, :stale_proposal}, state}
  end

  # Restrictions, the Projected Pantry, prices and the budget are read
  # again: concurrent changes by other Members are caught here.
  defp commit(state, shown) do
    household = HouseholdContext.load(state.account_id, state.user_id)

    state = %{
      state
      | household: household,
        instructions: HouseholdContext.instructions(household, state.range, state.slots)
    }

    ctx = %{
      account_id: state.account_id,
      range: state.range,
      slots: state.slots,
      household: household
    }

    with {:valid, meals} <- ProposalValidator.validate(Proposal.meals(shown), ctx),
         {current, purchase} = Proposal.build(meals, ctx),
         true <- Proposal.same_content?(current, shown) || {:stale, current},
         :ok <- approved(shown) do
      save(state, shown, purchase)
    else
      {:invalid, violations} ->
        {:reply, {:error, :revalidation_conflict},
         revalidation_conflict(state, shown, violations)}

      # Only the affected parts changed: the same meals are shown again,
      # recalculated, as a new Proposal the Member is asked to confirm.
      {:stale, current} ->
        emit(state, current)
        state = put_in(state.workspace.proposal, current)
        {:reply, {:error, :stale_proposal}, state}

      {:error, :approval_required} = error ->
        {:reply, error, state}
    end
  end

  # Deviation Approval is its own human action (#103); until it exists a
  # Proposal with Deviations cannot be confirmed.
  defp approved(%{"status" => "valid"}), do: :ok
  defp approved(_shown), do: {:error, :approval_required}

  defp save(state, shown, purchase) do
    attrs = %{
      confirmation_id: shown["proposal_id"],
      account_id: state.account_id,
      session_id: state.session_id,
      membership_id: state.membership_id,
      range: state.range,
      meals: Proposal.meals(shown),
      purchase: purchase
    }

    case Confirmation.run(state.confirmation_store, attrs, state.confirmation_opts) do
      {:ok, summary} ->
        confirmed(state, shown["proposal_id"], summary)

      {:error, :unresolved} ->
        emit(state, %{"type" => "confirmation_unresolved", "proposal_id" => shown["proposal_id"]})
        {:reply, {:error, :unresolved}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # The shown Proposal no longer passes validation: it is voided and the
  # agent is sent the violations to build a corrected one, which needs the
  # Member's confirmation again. With a reached limit pending, the Member
  # decides first whether the agent continues.
  defp revalidation_conflict(state, shown, violations) do
    emit(state, %{
      "type" => "proposal_invalidated",
      "proposal_id" => shown["proposal_id"],
      "reason" => "revalidation_conflict",
      "violations" => violations
    })

    state = put_in(state.workspace.proposal, nil)

    if state.consent? and state.pending_limit == nil do
      notice = %{role: :user, content: conflict_notice(violations)}
      start_turn(%{state | messages: state.messages ++ [notice]})
    else
      state
    end
  end

  # Code-authored: the Member asked to confirm and code found the
  # violations. Violations are generic and never name a Member.
  defp conflict_notice(violations) do
    "[Confirmation blocked by code] The Member tried to confirm the shown Proposal, but " <>
      "revalidation found violations: " <>
      Jason.encode!(violations) <>
      ". Nothing was saved. Build a corrected plan and present it with present_proposal."
  end

  # The Planning Session is committed with the confirmation: it ends without
  # expiring its row, and the Household's slot is free.
  defp confirmed(state, proposal_id, summary) do
    emit(state, %{
      "type" => "proposal_confirmed",
      "proposal_id" => proposal_id,
      "meals_count" => summary.meals_count,
      "shopping_lines_count" => summary.shopping_lines_count
    })

    emit(state, %{"type" => "session_ended"})
    {:stop, :normal, {:ok, summary}, %{state | session_id: nil}}
  end

  # ===========================================================================
  # Turn management
  # ===========================================================================

  defp start_turn(state) do
    session = self()
    holder = make_ref()

    deadline_at = System.monotonic_time(:millisecond) + state.deadline_ms
    presence = state.presence
    policies = state.call_policies

    turn = %{
      model: state.model,
      model_state: state.model_state,
      instructions: state.instructions,
      messages: state.messages,
      allowance: state.allowance,
      tool_context: %{
        account_id: state.account_id,
        session_id: state.session_id,
        range: state.range,
        slots: state.slots,
        household: state.household,
        optimizer: state.optimizer,
        recipe_search: state.recipe_search,
        workspace: state.workspace
      }
    }

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        ref = receive(do: ({^holder, ref} -> ref))
        emit_fun = fn event -> send(session, {:agent_event, ref, event}) end
        checkpoint = fn model_state -> send(session, {:model_state, ref, seal(model_state)}) end
        report_allowance = fn allowance -> send(session, {:allowance, ref, allowance}) end

        bounds =
          CallBounds.new(
            policies: policies,
            deadline_at: deadline_at,
            present?: fn -> :atomics.get(presence, 1) == 1 end,
            on_retry: fn kind, attempt, _reason ->
              emit_fun.(%{
                "type" => "progress",
                "step" => "retrying",
                "call" => Atom.to_string(kind),
                "attempt" => attempt
              })
            end
          )

        tool_context = turn.tool_context |> Map.put(:emit, emit_fun) |> Map.put(:bounds, bounds)

        result =
          %{turn | tool_context: tool_context, model_state: unseal(turn.model_state)}
          |> Map.put(:emit, emit_fun)
          |> Map.put(:bounds, bounds)
          |> Map.put(:checkpoint, checkpoint)
          |> Map.put(:report_allowance, report_allowance)
          |> Loop.run()

        %{result | model_state: seal(result.model_state)}
      end)

    send(task.pid, {holder, task.ref})
    deadline_ref = Process.send_after(self(), {:deadline, task.ref}, state.deadline_ms)
    %{state | task: task, deadline_ref: deadline_ref}
  end

  defp stop_turn(%{task: task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    # The task is dead, so every checkpoint it sent is already queued: adopt
    # the latest ones so the killed turn's paid usage and iterations stay
    # counted.
    clear_turn(%{
      state
      | model_state: latest_checkpoint(:model_state, task.ref, state.model_state),
        allowance: latest_checkpoint(:allowance, task.ref, state.allowance)
    })
  end

  defp latest_checkpoint(tag, ref, value) do
    receive do
      {^tag, ^ref, newer} -> latest_checkpoint(tag, ref, newer)
    after
      0 -> value
    end
  end

  # A running turn interrupted by Cancel, a lost lock or shutdown.
  defp cancel_run(%{task: nil} = state), do: state

  defp cancel_run(state) do
    state = stop_turn(state)
    emit(state, %{"type" => "run_finished", "outcome" => "cancelled"})
    state
  end

  # The run's terminal events come from its outcome. A reached limit stops
  # execution until the Member authorizes continuing.
  defp finish_run(state, :completed) do
    emit(state, %{"type" => "turn_completed"})
    emit(state, %{"type" => "run_finished", "outcome" => "complete"})
    state
  end

  defp finish_run(state, {:limit_reached, limit}) do
    emit(state, %{"type" => "limit_reached", "limit" => limit, "requires_authorization" => true})
    emit(state, %{"type" => "run_finished", "outcome" => "partial"})
    %{state | pending_limit: limit}
  end

  defp finish_run(state, {:failed, reason}) do
    emit(state, %{"type" => "agent_unavailable", "reason" => reason_string(reason)})
    emit(state, %{"type" => "run_finished", "outcome" => "failure"})
    state
  end

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason), do: "provider_error"

  defp clear_turn(state) do
    if state.deadline_ref, do: Process.cancel_timer(state.deadline_ref)
    %{state | task: nil, deadline_ref: nil}
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # The model state holds the provider API key. It travels and is stored
  # sealed in a closure, which inspects as `#Function<...>`, so status
  # output, crash reports and stacktrace arguments never print the key.
  # Only the turn process unseals it, right before calling the model.
  defp seal(model_state), do: fn -> model_state end
  defp unseal(sealed) when is_function(sealed, 0), do: sealed.()

  defp add_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid) do
      state
    else
      :atomics.put(state.presence, 1, 1)
      %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
    end
  end

  defp emit(state, event) do
    case sanitize(event) do
      nil ->
        Logger.warning("planning agent dropped an event outside the allowlist")

      event ->
        Enum.each(Map.keys(state.subscribers), fn pid ->
          send(pid, {:planning_agent_event, state.session_id, event})
        end)
    end
  end

  @event_fields %{
    "progress" => ~w(step call attempt tool outcome),
    "assistant_message" => ~w(text),
    "question" => ~w(text),
    "proposal" => ~w(proposal_id status meals purchase consumed_cost budget deviations),
    "optimizer_failed" => ~w(reason),
    "consent_required" => [],
    "limit_reached" => ~w(limit requires_authorization),
    "agent_unavailable" => ~w(reason),
    "turn_completed" => [],
    "run_finished" => ~w(outcome),
    "session_cancelled" => [],
    "session_ended" => [],
    "proposal_confirmed" => ~w(proposal_id meals_count shopping_lines_count),
    "proposal_invalidated" => ~w(proposal_id reason violations),
    "confirmation_unresolved" => ~w(proposal_id)
  }
  @meal_fields ~w(date slot recipe_id name)

  # Streaming carries progress only: known event types with known fields.
  # Anything else, such as raw tool output or model reasoning, is dropped.
  defp sanitize(%{"type" => type} = event) when is_map_key(@event_fields, type) do
    event
    |> Map.take(["type" | Map.fetch!(@event_fields, type)])
    |> Map.replace_lazy("meals", fn meals ->
      Enum.map(List.wrap(meals), &Map.take(&1, @meal_fields))
    end)
  end

  defp sanitize(_event), do: nil

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
