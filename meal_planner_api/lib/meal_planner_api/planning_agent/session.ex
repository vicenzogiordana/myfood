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
    * `stop/2` — Stop: halts the running turn; the Planning Session, its
      Workspace and the last valid Proposal survive (session's Member only).
    * `authorize_continuation/2` — the session Member's explicit
      authorization to continue after a limit was reached.
    * `cancel/2` — Cancel: ends the session and discards its Workspace
      (session's Member or Household Owner).
    * `current_proposal/1` — the last valid Proposal shown, or `nil`.
    * `confirm/3` — the session Member's confirmation of the exact displayed
      Proposal: saves its Planned Meals and appends its Purchase to the
      Shopping List (see "Confirmation").
    * `save_recipe/3` — the session Member's explicit save of a dictated
      Recipe Draft as a user-created Household Recipe (see "Recipe Drafts")
    * `confirmation_status/2` — the status of a confirmation, queryable after
      the Planning Session ended.
    * `approve_deviations/3` — the session Member's Deviation Approval of the
      exact displayed Proposal (see "Approvals").
    * `approve_absence_exception/3` — the session Member's Absence Exception
      for an absent Member (see "Approvals").
    * `resume/2` — the session Member's return: rejoins the Planning
      Session within its grace, restoring it after a restart (see "Absence
      grace" and "Restart recovery").
    * `cancel_recoverable/2` — Cancel of a session waiting for recovery
    * `whereis/1` — the active session process of a Household, if any.

  ## Events

  Subscribers receive `{:planning_agent_event, session_id, event}` where
  `event["type"]` is one of `progress`, `assistant_message`, `question`,
  `proposal`, `recipe_draft`, `recipe_saved`, `optimizer_failed`, `session_brand_changed`,
  `consent_required`, `limit_reached`, `session_budget_exhausted`,
  `agent_unavailable`, `turn_completed`, `run_finished`, `stopped`, `session_cancelled`,
  `session_ended`, `proposal_confirmed`, `proposal_invalidated`,
  `confirmation_unresolved`, `deviations_approved`, `absence_exception_approved`,
  `session_recovered`.

  Every run (one request, or one authorized continuation) ends with exactly
  one `run_finished` event whose `outcome` is `complete`, `partial` (stopped
  by a limit), `failure`, `cancelled`, `interrupted` (the Member left) or
  `unknown` (the turn crashed). Every
  tool result carries its own outcome kind (see `MealPlannerApi.PlanningAgent.Tools`).

  Streaming carries progress only: every event passes an allowlist of types
  and fields before it is sent, so raw tool output, tool arguments and model
  reasoning never reach subscribers.

  ## Limits

    * `max_iterations` agent iterations (model calls, default 15) per Member
      message; every message starts its own
    * `max_session_iterations` model calls (default 60) per Planning
      Session, never extended (see `MealPlannerApi.PlanningAgent.Allowance`);
      a call refused before it reached the provider never counts
    * 3 consecutive attempts without verifiable progress
    * a global deadline per request (default 5 minutes) after which the
      running turn is killed and its late results are discarded
    * per-call deadlines and retry budgets
      (see `MealPlannerApi.PlanningAgent.CallBounds`)

  Reaching the message's iterations, the no-progress streak or the deadline
  stops the run and emits `limit_reached` with
  `"requires_authorization" => true`. When the latest tool result of the
  turn was a service failure, an `assistant_message` rendered by code
  precedes it, naming the failing tools and their failure kinds. From then on `send_message/2` refuses
  with `:authorization_required` until the session's Member calls
  `authorize_continuation/2`, which extends only the reached limit and
  resumes the request.

  The spend and token caps of the model adapter and the session's iteration
  ceiling are per Planning Session and never extended: the adapter's ledger
  is initialised once at start and carried across turns, so neither Stop
  nor a new message resets it. Exhausting any of them ends the agent's part
  of the session gracefully (issue #154): it emits `session_budget_exhausted`
  with `limit` (`spend_cap`, `token_cap` or `session_iterations`), a
  code-rendered `message` and the latest Proposal (or `nil`), and
  `send_message/2` refuses with `:session_budget_exhausted` without a turn.
  Without a Proposal the session then ends (`session_ended`) and releases the
  Household's slot; with one it stays open for the Member to confirm,
  approve or cancel it.

  ## Start rate limit

  A Household starts at most `max_starts` Planning Sessions within a
  sliding window of `window_seconds` (`:session_start_limit`, issue #118);
  a start over it is refused with `:session_start_rate_limited` and leaves
  nothing behind. Every stored Planning Session counts, whatever its end.
  The limit is a human decision with no default: without a valid one every
  start is refused with `:spend_caps_unconfigured`. Recovering a session
  after a restart is not a start and is never limited.

  ## Stop and Cancel

  Both halt the running turn immediately with a `:brutal_kill`, adopt what
  it already checkpointed (paid usage, counted iterations and the
  Workspace, so a Proposal it presented survives a Stop), discard
  everything else it sends later, and force-kill every optimizer OS process
  it started, waiting until each is gone. Only then does Stop reply or
  Cancel release the Household's slot, so old work can no longer act. A
  halted run ends with `run_finished` outcome `cancelled`; Stop then emits
  `stopped`. The same halt runs at the time limit and on shutdown.

  ## Confirmation

  Only the Member's confirmation saves a plan; no agent tool can. It names
  the exact displayed Proposal by its `proposal_id`, which is also the
  confirmation identity (`MealPlannerApi.PlanningAgent.Confirmation`). The
  Planning Session then ends as committed and releases the Household's slot.
  A replay of the same confirmation returns the original result, even after
  the session ended, and never saves twice.

  ## Recipe Drafts

  `create_recipe` keeps Recipe Drafts in the Workspace only
  (`MealPlannerApi.PlanningAgent.RecipeDraft`); a session that ends
  unconfirmed discards them. Confirming a Proposal saves the AI-created
  Drafts it uses as private AI-created Household Recipes. A dictated
  (user-created) Draft is never planned or saved by the agent: only
  `save_recipe/3` saves it, as a user-created Household Recipe.

  ## Approvals

  Approvals are human-only actions; the agent can only ask for them, no
  tool grants them, and a turn can never set or change them in the
  Workspace.

  A Deviation Approval is one all-or-nothing acceptance of every Deviation
  of the exact Proposal shown. It is bound to that Proposal's identity and
  Deviations: any change to the Proposal (a new one from the agent, or one
  recalculated at confirmation) voids it. A `requires_approval` Proposal is
  confirmed only with its own approval. Approving never changes the
  Household's stored budget or Nutrition Goal.

  An Absence Exception lifts one Restriction of one Member, who is absent,
  for specific meals of the Planning Range. The validator accepts exactly
  those meals where only that Restriction blocked them, in
  `present_proposal` and at confirmation. It never edits a profile, lives
  only in this session's Workspace and so is never inherited when meals are
  reused.

  The model state is created once at `start/2` and kept across Member
  messages, so the spend and token caps are never reset between requests.

  ## Absence grace

  The Member is absent while no subscriber is connected. Leaving or
  disconnecting keeps the Planning Session, its Workspace, the last
  Proposal and the Household's slot for a grace of `:grace_ms` (default
  15 minutes): the session's lease is fixed to the grace deadline. While
  the Member is absent no new model call starts (a call already in flight
  may finish, then the run ends with `run_finished` outcome `interrupted`)
  and nothing is saved: `confirm/3` and `save_recipe/3` refuse with
  `:member_absent`. `resume/2` within the grace cancels the expiry; it is
  refused with `:forbidden` for anyone but the session's Member, and for a
  Member no longer active in the Household. When the grace expires the
  running work is cancelled, the Workspace discarded and the slot released.

  ## Idle expiry

  A Member who stays connected but does nothing does not hold the slot
  forever: after `:idle_ms` (default 30 minutes) without a Member action
  (any call but `info/1` and `current_proposal/1`) and without a running
  turn, the session ends with `session_ended`, its Workspace discarded and
  the slot released. A running turn is never cut; the idle time restarts
  when it ends.

  ## Restart recovery

  The durable state (transcript, Workspace, allowance, pending limit and the
  model adapter's recoverable part, never credentials; see
  `MealPlannerApi.PlanningAgent.Model`) is written to recoverable storage
  whenever it changes, and deleted whenever the Planning Session ends. A
  shutdown or crash keeps the row, its lease and the snapshot. There is no
  unattended restart: only the Member's `resume/2` within the grace (the
  row's lease, which a restart never extends) starts a process from the
  snapshot, after checking the Member is still active in the Household.
  Nothing is replayed: a request that was running is not resumed (the
  agent is told so and `session_recovered` carries `interrupted: true`), an
  unsettled model reservation counts as spent, and a confirmation that was
  in flight is reconciled by the row itself, since a committed session is
  never restored. Neither the grace nor any limit resets.
  """

  use GenServer, restart: :temporary

  require Logger

  import Ecto.Query, only: [from: 2]

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Planning.PlanningSession

  alias MealPlannerApi.PlanningAgent.{
    Allowance,
    CallBounds,
    Confirmation,
    HouseholdContext,
    Loop,
    Model,
    OsProcess,
    Proposal,
    ProposalValidator,
    RecipeDraft,
    Workspace
  }

  alias MealPlannerApi.Planning.RecipeOrigin
  alias MealPlannerApi.Repo

  @registry MealPlannerApi.PlanningAgent.Registry
  @supervisor MealPlannerApi.PlanningAgent.SessionSupervisor
  @task_supervisor MealPlannerApi.PlanningAgent.TaskSupervisor

  @default_max_iterations 15
  @default_max_session_iterations 60
  @default_deadline_ms 5 * 60 * 1000
  @default_grace_ms 15 * 60 * 1000
  @default_idle_ms 30 * 60 * 1000
  # While the Member is present the lease covers at least this long, so the
  # sweeper never expires a session that is still renewing it.
  @min_lease_ms 120_000
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
    * `:max_iterations`, `:max_session_iterations`, `:deadline_ms` —
      execution limits (see "Limits")
    * `:call_policies` — per-kind overrides of the per-call deadlines and
      retry budgets (see `MealPlannerApi.PlanningAgent.CallBounds`)
    * `:recipe_search` — `{module, opts}` replacing the recipe search read
      tool (`module.search(household, filters, opts)`), for tests
    * `:price_scraper` — `{module, opts}` implementing
      `MealPlannerApi.PlanningAgent.PriceScraper` for live price lookups
      (default from config)
    * `:clock` — a 0-arity function returning the current `DateTime`, used
      to age prices (default: `DateTime.utc_now/0`)
    * `:confirmation_store` — `{module, opts}` replacing the confirmation
      store (see `MealPlannerApi.PlanningAgent.Confirmation`), for tests
    * `:reconcile_ms`, `:poll_ms` — how long and how often a lost
      confirmation acknowledgement is reconciled (default 30 s and 1 s)
    * `:session_start_limit` — `{max_starts, window_seconds}` (default from
      `config :meal_planner_api, :planning_agent`), see "Start rate limit"
    * `:grace_ms` — the absence grace (default 15 minutes)
    * `:idle_ms` — the idle expiry (default 30 minutes)
  """
  @spec start(attrs(), keyword()) ::
          {:ok, %{session_id: Ecto.UUID.t(), pid: pid()}}
          | {:error,
             :invalid_range
             | :invalid_slots
             | :range_already_planned
             | :session_already_active
             | :session_start_rate_limited
             | :spend_caps_unconfigured
             | term()}
  def start(attrs, opts \\ []) do
    {model, model_opts} = Keyword.get_lazy(opts, :model, fn -> config(:model) end)

    with {:ok, start_limit} <-
           start_limit(
             Keyword.get_lazy(opts, :session_start_limit, fn -> config(:session_start_limit) end)
           ),
         {:ok, {from_date, to_date}} <- validate_range(attrs.range),
         :ok <- validate_slots(attrs.slots),
         :ok <- ensure_unplanned(attrs.account_id, from_date, to_date),
         {:ok, model_state} <- model.init(model_opts),
         grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms),
         {:ok, row} <- lock(attrs, from_date, to_date, grace_ms, start_limit) do
      init_args = init_args(attrs, row.id, {model, model_state}, nil, opts)

      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, init_args}) do
        {:ok, pid} ->
          {:ok, %{session_id: row.id, pid: pid}}

        {:error, reason} ->
          _ = PlanningRepo.expire_session(attrs.account_id, row.id)
          {:error, reason}
      end
    end
  end

  defp init_args(attrs, session_id, {model, model_state}, recovered, opts) do
    %{
      attrs: attrs,
      session_id: session_id,
      model: model,
      model_state: seal(model_state),
      recovered: recovered,
      optimizer: Keyword.get_lazy(opts, :optimizer, fn -> config(:optimizer) end),
      subscriber: Keyword.get(opts, :subscriber),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      max_session_iterations:
        Keyword.get(opts, :max_session_iterations, @default_max_session_iterations),
      deadline_ms: Keyword.get(opts, :deadline_ms, @default_deadline_ms),
      call_policies: Keyword.get(opts, :call_policies, %{}),
      recipe_search: Keyword.get(opts, :recipe_search),
      price_scraper: Keyword.get_lazy(opts, :price_scraper, fn -> config(:price_scraper) end),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      confirmation_store: Keyword.get_lazy(opts, :confirmation_store, &Confirmation.store/0),
      confirmation_opts: Keyword.take(opts, [:reconcile_ms, :poll_ms]),
      grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms)
    }
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
             | :authorization_required
             | :session_budget_exhausted}
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

  @doc """
  Stops the agent's current work. The Planning Session, its Workspace and the
  last valid Proposal survive, and the Member can send a new message. Only
  the session's Member may Stop; an idle session replies `:ok` too.
  """
  @spec stop(GenServer.server(), %{membership_id: Ecto.UUID.t(), owner?: boolean()}) ::
          :ok | {:error, :forbidden}
  def stop(session, actor), do: GenServer.call(session, {:stop, actor})

  @doc "The last valid Proposal shown in this Planning Session, or `nil`."
  @spec current_proposal(GenServer.server()) :: map() | nil
  def current_proposal(session), do: GenServer.call(session, :current_proposal)

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
  The session Member's explicit save of the dictated Recipe Draft
  `recipe_id`: it becomes a user-created Household Recipe with the same id
  and leaves the Workspace. Refuses with `:forbidden` for anyone else,
  `:busy` while the agent is working, `:not_found` when no such Draft is in
  the Workspace, and `:not_dictated` for an AI-created Draft, which only a
  confirmation saves.
  """
  @spec save_recipe(GenServer.server(), Ecto.UUID.t(), String.t()) ::
          {:ok, %{recipe_id: Ecto.UUID.t(), name: String.t(), origin: String.t()}}
          | {:error, :forbidden | :busy | :not_found | :not_dictated | :invalid_recipe}
  def save_recipe(session, membership_id, recipe_id),
    do: GenServer.call(session, {:save_recipe, membership_id, recipe_id})

  @doc """
  The status of the confirmation `proposal_id` in the Household:
  `{:confirmed, summary}`, `:not_found`, or `:unknown` while it cannot be read.
  """
  @spec confirmation_status(Ecto.UUID.t(), String.t()) ::
          {:confirmed, Confirmation.summary()} | :not_found | :unknown
  def confirmation_status(account_id, proposal_id),
    do: Confirmation.lookup(Confirmation.store(), account_id, proposal_id)

  @doc """
  The session Member's Deviation Approval of the Proposal `proposal_id` in
  the Household `account_id`: accepts every Deviation of that exact
  Proposal, all or nothing. Refuses with:

    * `:forbidden` — not the session's Member
    * `:busy` — the agent is working; the shown Proposal may be replaced
    * `:stale_proposal` — not the current Proposal; the Member is shown it
      again
    * `:no_deviations` — the Proposal is valid and needs no approval
    * `:session_not_active` — no Planning Session is running
  """
  @spec approve_deviations(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          :ok
          | {:error, :forbidden | :busy | :stale_proposal | :no_deviations | :session_not_active}
  def approve_deviations(account_id, membership_id, proposal_id),
    do: human_action(account_id, {:approve_deviations, membership_id, proposal_id})

  @doc """
  The session Member's Absence Exception in the Household `account_id`:
  `%{member_id: user_id, restriction: restriction, meals: [{date, slot}]}`
  lifts `restriction` (`{:diet, diet}` or `{:allergy, tag}`, as in
  `MealPlannerApi.Planning.Restrictions`) of the absent Member `user_id` for
  exactly `meals`. Refuses with:

    * `:forbidden` — not the session's Member
    * `:busy` — the agent is working
    * `:invalid_absence_exception` — not a Restriction that Member holds, or
      meals outside the Planning Range and its slots
    * `:session_not_active` — no Planning Session is running
  """
  @spec approve_absence_exception(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          :ok
          | {:error, :forbidden | :busy | :invalid_absence_exception | :session_not_active}
  def approve_absence_exception(account_id, membership_id, exception),
    do: human_action(account_id, {:approve_absence_exception, membership_id, exception})

  defp human_action(account_id, message) do
    case whereis(account_id) do
      nil ->
        {:error, :session_not_active}

      pid ->
        try do
          GenServer.call(pid, message)
        catch
          :exit, {reason, _} when reason in [:noproc, :normal] -> {:error, :session_not_active}
        end
    end
  end

  defp replayed(account_id, proposal_id) do
    case confirmation_status(account_id, proposal_id) do
      {:confirmed, summary} -> {:ok, summary}
      :not_found -> {:error, :stale_proposal}
      :unknown -> {:error, :unresolved}
    end
  end

  @doc """
  The session Member's return to the Household's Planning Session within its
  grace: `attrs` names the Member (`account_id`, `user_id`, `membership_id`)
  and `opts[:subscriber]` the pid that receives events from now on. Replies
  with the session and its last valid Proposal, so a reconnecting client
  reads authoritative state. Refuses with:

    * `:forbidden` — not the session's Member, or no longer an active
      Member of the Household
    * `:no_session` — no Planning Session to return to (it ended, or its
      grace expired)
    * `:session_busy` — the running session did not answer within
      `opts[:rejoin_timeout]` (5 seconds by default); it is left running
  """
  @spec resume(map(), keyword()) ::
          {:ok, %{session_id: Ecto.UUID.t(), pid: pid(), proposal: map() | nil}}
          | {:error, :forbidden | :no_session | :session_busy | term()}
  def resume(attrs, opts \\ []) do
    subscriber = Keyword.get(opts, :subscriber)

    with :ok <- ensure_active_member(attrs) do
      case whereis(attrs.account_id) do
        nil ->
          recover(attrs, opts)

        pid ->
          # The process may stop meanwhile; a restart-like stop leaves the
          # session recoverable.
          with {:error, :no_session} <- rejoin(pid, attrs, subscriber, rejoin_timeout(opts)),
               do: recover(attrs, opts)
      end
    end
  end

  defp rejoin_timeout(opts), do: Keyword.get(opts, :rejoin_timeout, 5_000)

  # A session that does not answer in time is still alive: the return is
  # refused as busy and never recovers it, which would run it twice. Any
  # other stop during the call (a restart, or a crash that kept its
  # snapshot) leaves the session to recovery.
  defp rejoin(pid, attrs, subscriber, timeout) do
    GenServer.call(pid, {:resume, attrs.membership_id, subscriber}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :session_busy}
    :exit, _reason -> {:error, :no_session}
  end

  # No process runs the session (the server restarted): it is restored from
  # its snapshot, on the Member's return only, while its grace lasts. The
  # row's status reconciles a confirmation that was in flight: a committed
  # session is no longer active and is never restored.
  defp recover(attrs, opts) do
    {model, model_opts} = Keyword.get_lazy(opts, :model, fn -> config(:model) end)

    with %PlanningSession{} = row <-
           PlanningRepo.active_household_session(attrs.account_id) || {:error, :no_session},
         {:ok, binary} <- recovery_snapshot(row),
         :ok <- within_grace(row),
         :ok <- own_session(row, attrs),
         {:ok, saved} <- decode_snapshot(binary),
         {:ok, model_state} <- Model.recover(model, model_opts, saved.model) do
      session_attrs = %{
        account_id: row.account_id,
        user_id: saved.user_id,
        membership_id: saved.membership_id,
        role: saved.role,
        range: saved.range,
        slots: saved.slots
      }

      args = init_args(session_attrs, row.id, {model, model_state}, saved, opts)

      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, args}) do
        {:ok, pid} ->
          {:ok, %{session_id: row.id, pid: pid, proposal: saved.workspace.proposal}}

        # Another return of the same Member restored it first.
        {:error, _reason} ->
          case whereis(attrs.account_id) do
            nil -> {:error, :no_session}
            pid -> rejoin(pid, attrs, Keyword.get(opts, :subscriber), rejoin_timeout(opts))
          end
      end
    end
  end

  # Only agent sessions keep a snapshot; a legacy planning row has none.
  defp recovery_snapshot(row) do
    case PlanningRepo.fetch_recovery(row.id) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :no_session}
    end
  end

  # The grace is the row's lease and never resets: once it passed, the
  # session is expired and its Workspace discarded.
  defp within_grace(row) do
    if DateTime.compare(row.lease_expires_at, DateTime.utc_now()) == :gt do
      :ok
    else
      _ = PlanningRepo.expire_session(row.account_id, row.id)
      {:error, :no_session}
    end
  end

  defp own_session(row, attrs) do
    if row.lock_owner_membership_id == attrs.membership_id,
      do: :ok,
      else: {:error, :forbidden}
  end

  @doc """
  Cancels the Household's Planning Session while it waits for recovery (no
  process runs it after a restart), discarding its Workspace and freeing the
  slot. Allowed for the session's Member and the Owner, like `cancel/2`.
  Refuses with `:no_session` when there is none, and with `:session_running`
  when a process runs it (use `cancel/2`).
  """
  @spec cancel_recoverable(Ecto.UUID.t(), %{membership_id: Ecto.UUID.t(), owner?: boolean()}) ::
          :ok | {:error, :forbidden | :no_session | :session_running}
  def cancel_recoverable(account_id, %{membership_id: actor, owner?: owner?}) do
    with %PlanningSession{} = row <-
           PlanningRepo.active_household_session(account_id) || {:error, :no_session},
         {:ok, _binary} <- recovery_snapshot(row),
         nil <- whereis(account_id) do
      case PlanningRepo.cancel_session(account_id, row.id, actor, owner? == true) do
        {:ok, _cancelled} -> :ok
        {:error, :forbidden} -> {:error, :forbidden}
        {:error, :not_active} -> {:error, :no_session}
      end
    else
      pid when is_pid(pid) -> {:error, :session_running}
      error -> error
    end
  end

  # Revoked access blocks the return: the Member must still hold an active
  # membership of this Household.
  defp ensure_active_member(%{account_id: account_id, user_id: user_id, membership_id: id}) do
    active? =
      Repo.exists?(
        from(m in AccountMembership,
          where:
            m.id == ^id and m.account_id == ^account_id and m.user_id == ^user_id and
              m.status == :active
        )
      )

    if active?, do: :ok, else: {:error, :forbidden}
  end

  @doc "Returns the session id and owning membership of a running session."
  @spec info(GenServer.server()) :: %{session_id: Ecto.UUID.t(), membership_id: Ecto.UUID.t()}
  def info(session), do: GenServer.call(session, :info)

  @doc "The running session process of a Household, or `nil`."
  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(account_id) do
    # The Registry forgets a dead process asynchronously: a session that
    # just stopped (a shutdown or crash) is not running any more.
    case Registry.lookup(@registry, {:household, account_id}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
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

    # An old process can still hold the Household's name after its lock was
    # released (a cancel whose process is still exiting, or a row expired
    # behind it until its next lease renewal): the start is refused, never
    # crashed.
    case Registry.register(@registry, {:household, attrs.account_id}, args.session_id) do
      {:ok, _owner} -> {:ok, init_state(args)}
      {:error, {:already_registered, _pid}} -> {:stop, :session_already_active}
    end
  end

  defp init_state(%{attrs: attrs} = args) do
    household = HouseholdContext.load(attrs.account_id, attrs.user_id)
    saved = args.recovered

    state = %{
      session_id: args.session_id,
      account_id: attrs.account_id,
      user_id: attrs.user_id,
      membership_id: attrs.membership_id,
      role: attrs.role,
      range: attrs.range,
      slots: attrs.slots,
      household: household,
      consent?: household.consent?,
      instructions: HouseholdContext.instructions(household, attrs.range, attrs.slots),
      model: args.model,
      model_state: args.model_state,
      optimizer: args.optimizer,
      messages: if(saved, do: recovered_messages(saved), else: []),
      workspace: if(saved, do: saved.workspace, else: Workspace.new()),
      subscribers: %{},
      task: nil,
      deadline_ref: nil,
      os_pids: MapSet.new(),
      allowance: allowance(args, saved),
      pending_limit: saved && saved.pending_limit,
      exhausted: saved && Map.get(saved, :exhausted),
      deadline_ms: args.deadline_ms,
      call_policies: CallBounds.policies(args.call_policies),
      recipe_search: args.recipe_search,
      price_scraper: args.price_scraper,
      clock: args.clock,
      confirmation_store: args.confirmation_store,
      confirmation_opts: args.confirmation_opts,
      # Read by the running turn without a message round trip: no retry
      # starts while no Member is connected.
      presence: :atomics.new(1, []),
      grace_ms: args.grace_ms,
      grace_ref: nil,
      grace_deadline: nil,
      idle_ms: args.idle_ms,
      idle_ref: nil,
      idle_timer: nil,
      persisted: nil
    }

    state =
      if args.subscriber, do: add_subscriber(state, args.subscriber), else: go_absent(state)

    if saved do
      # The Member is back: a new grace starts only when they leave again.
      if args.subscriber, do: _ = renew_lease(state)
      emit(state, %{"type" => "session_recovered", "interrupted" => saved.running?})
    end

    schedule_lease_renewal()
    state |> touch() |> persist()
  end

  # Every change to the durable state is written to recoverable storage
  # before the next message, so a restart finds the latest Workspace.
  @impl true
  def handle_call(message, from, state),
    do: message |> do_call(from, member_activity(message, state)) |> persisted()

  @impl true
  def handle_info(message, state), do: message |> do_info(state) |> persisted()

  defp persisted({:reply, reply, state}), do: {:reply, reply, persist(state)}
  defp persisted({:noreply, state}), do: {:noreply, persist(state)}
  defp persisted(stop), do: stop

  defp do_call(:record_consent, _from, state) do
    case MealPlannerApi.PlanningAgent.Consent.record(state.account_id, state.user_id) do
      :ok -> {:reply, :ok, %{state | consent?: true}}
      error -> {:reply, error, state}
    end
  end

  defp do_call({:send_message, text}, _from, state) do
    cond do
      not is_binary(text) or String.trim(text) == "" ->
        {:reply, {:error, :invalid_message}, state}

      byte_size(text) > @max_message_bytes ->
        {:reply, {:error, :message_too_long}, state}

      not state.consent? ->
        emit(state, %{"type" => "consent_required"})
        {:reply, {:error, :consent_required}, state}

      # Nothing the agent could do any more: the Member is shown why again,
      # never a turn that can only be refused (issue #154).
      state.exhausted != nil ->
        emit(state, budget_exhausted_event(state))
        {:reply, {:error, :session_budget_exhausted}, state}

      state.task != nil ->
        {:reply, {:error, :busy}, state}

      state.pending_limit != nil ->
        {:reply, {:error, :authorization_required}, state}

      true ->
        # The Member's message answers any budget Deviation: from now on the
        # agent may draft recipes if they asked for them (issue #148). It
        # also starts its own iterations.
        state = %{
          state
          | messages: state.messages ++ [%{role: :user, content: text}],
            workspace: Map.put(state.workspace, :budget_conflict, nil),
            allowance: Allowance.start_message(state.allowance)
        }

        {:reply, :ok, start_turn(state)}
    end
  end

  defp do_call({:authorize_continuation, membership_id}, _from, state) do
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

  defp do_call({:subscribe, pid}, _from, state), do: {:reply, :ok, add_subscriber(state, pid)}

  defp do_call({:resume, membership_id, _subscriber}, _from, state)
       when membership_id != state.membership_id,
       do: {:reply, {:error, :forbidden}, state}

  defp do_call({:resume, _membership_id, subscriber}, _from, state) do
    state = if is_pid(subscriber), do: add_subscriber(state, subscriber), else: state
    reply = %{session_id: state.session_id, pid: self(), proposal: state.workspace.proposal}
    {:reply, {:ok, reply}, state}
  end

  defp do_call({:stop, %{membership_id: actor}}, _from, state) do
    if actor == state.membership_id do
      state = cancel_run(state)
      emit(state, %{"type" => "stopped"})
      {:reply, :ok, state}
    else
      {:reply, {:error, :forbidden}, state}
    end
  end

  defp do_call(:current_proposal, _from, state),
    do: {:reply, state.workspace.proposal, state}

  defp do_call(:info, _from, state),
    do: {:reply, %{session_id: state.session_id, membership_id: state.membership_id}, state}

  defp do_call({:cancel, %{membership_id: actor, owner?: owner?}}, _from, state) do
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

  defp do_call({:confirm, membership_id, _proposal_id}, _from, state)
       when membership_id != state.membership_id,
       do: {:reply, {:error, :forbidden}, state}

  defp do_call({:confirm, _membership_id, proposal_id}, _from, state) do
    case Confirmation.lookup(state.confirmation_store, state.account_id, proposal_id) do
      {:confirmed, summary} ->
        if own_proposal?(state, proposal_id),
          do: confirmed(state, proposal_id, summary),
          else: {:reply, {:ok, summary}, state}

      _not_confirmed ->
        confirm_current(state, proposal_id)
    end
  end

  defp do_call({:save_recipe, membership_id, _recipe_id}, _from, state)
       when membership_id != state.membership_id,
       do: {:reply, {:error, :forbidden}, state}

  defp do_call({:save_recipe, _membership_id, _recipe_id}, _from, %{task: %Task{}} = state),
    do: {:reply, {:error, :busy}, state}

  defp do_call({:save_recipe, _membership_id, _recipe_id}, _from, %{subscribers: subs} = state)
       when map_size(subs) == 0,
       do: {:reply, {:error, :member_absent}, state}

  defp do_call({:save_recipe, _membership_id, recipe_id}, _from, state) do
    case Map.fetch(state.workspace.recipe_drafts, recipe_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{source: :user_created} = draft} ->
        save_dictated(state, draft)

      {:ok, _ai_created} ->
        {:reply, {:error, :not_dictated}, state}
    end
  end

  defp do_call({:approve_deviations, membership_id, _proposal_id}, _from, state)
       when membership_id != state.membership_id,
       do: {:reply, {:error, :forbidden}, state}

  defp do_call(
         {:approve_deviations, _membership_id, _proposal_id},
         _from,
         %{task: %Task{}} = state
       ),
       do: {:reply, {:error, :busy}, state}

  defp do_call({:approve_deviations, _membership_id, proposal_id}, _from, state) do
    case state.workspace.proposal do
      %{"proposal_id" => ^proposal_id, "status" => "requires_approval"} = shown ->
        approval = %{proposal_id: proposal_id, deviations: shown["deviations"]}

        emit(state, %{
          "type" => "deviations_approved",
          "proposal_id" => proposal_id,
          "deviations" => shown["deviations"]
        })

        {:reply, :ok, put_in(state.workspace.deviation_approval, approval)}

      %{"proposal_id" => ^proposal_id} ->
        {:reply, {:error, :no_deviations}, state}

      current ->
        if current, do: emit(state, current)
        {:reply, {:error, :stale_proposal}, state}
    end
  end

  defp do_call({:approve_absence_exception, membership_id, _exception}, _from, state)
       when membership_id != state.membership_id,
       do: {:reply, {:error, :forbidden}, state}

  defp do_call(
         {:approve_absence_exception, _membership_id, _exception},
         _from,
         %{task: %Task{}} = state
       ),
       do: {:reply, {:error, :busy}, state}

  defp do_call({:approve_absence_exception, _membership_id, exception}, _from, state) do
    case absence_exception(state, exception) do
      {:ok, exception} ->
        meals =
          Enum.map(exception.meals, fn {date, slot} ->
            %{"date" => Date.to_iso8601(date), "slot" => slot}
          end)

        # Generic: neither the event nor the agent learns whose Restriction
        # it is or which one.
        emit(state, %{"type" => "absence_exception_approved", "meals" => meals})
        notice = %{role: :user, content: absence_notice(meals)}

        state = %{
          state
          | workspace: Map.update!(state.workspace, :absence_exceptions, &(&1 ++ [exception])),
            messages: state.messages ++ [notice]
        }

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :invalid_absence_exception}, state}
    end
  end

  defp do_info({:agent_event, ref, event}, %{task: %Task{ref: ref}} = state) do
    emit(state, event)
    {:noreply, state}
  end

  # Events of a killed turn arrive late: they are discarded.
  defp do_info({:agent_event, _stale_ref, _event}, state), do: {:noreply, state}

  # Model state checkpoints carry paid usage (spend ledger), so the session
  # keeps it even when the turn is later killed or crashes.
  defp do_info({:model_state, ref, sealed}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | model_state: sealed}}

  defp do_info({:model_state, _stale_ref, _model_state}, state), do: {:noreply, state}

  # Allowance checkpoints keep counted iterations of a turn that is killed.
  defp do_info({:allowance, ref, allowance}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | allowance: allowance}}

  defp do_info({:allowance, _stale_ref, _allowance}, state), do: {:noreply, state}

  # Workspace checkpoints let a Stop keep what tools already produced.
  defp do_info({:workspace, ref, workspace}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | workspace: adopt_workspace(state.workspace, workspace)}}

  defp do_info({:workspace, _stale_ref, _workspace}, state), do: {:noreply, state}

  defp do_info({:os_process, ref, event}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, track_os_process(state, event)}

  # A process reported by a turn that is already halted is killed at once.
  defp do_info({:os_process, _stale_ref, {:started, os_pid}}, state) do
    _ = OsProcess.kill(os_pid)
    {:noreply, state}
  end

  defp do_info({:os_process, _stale_ref, _event}, state), do: {:noreply, state}

  defp do_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    # A finished turn closed every optimizer it opened.
    state = %{
      clear_turn(%{state | os_pids: MapSet.new()})
      | model_state: result.model_state,
        messages: result.messages,
        workspace: adopt_workspace(state.workspace, result.workspace),
        allowance: result.allowance
    }

    state |> finish_run(result.outcome) |> after_run()
  end

  # A turn that replied just before the deadline finished on its own, so its
  # outcome stands; otherwise the run reached its time limit.
  defp do_info({:deadline, ref}, %{task: %Task{ref: ref}} = state) do
    case halt_turn(state) do
      {state, {:ok, result}} -> state |> finish_run(result.outcome) |> after_run()
      {state, _shutdown} -> {:noreply, finish_run(state, {:limit_reached, "time"})}
    end
  end

  defp do_info({:deadline, _stale}, state), do: {:noreply, state}

  defp do_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("planning agent turn crashed: #{inspect(reason)}")
    state = state |> adopt_checkpoints(ref) |> kill_os_processes() |> clear_turn()
    emit(state, %{"type" => "agent_unavailable", "reason" => "internal_error"})
    emit(state, %{"type" => "run_finished", "outcome" => "unknown"})
    {:noreply, state}
  end

  defp do_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.subscribers, pid) do
      {^ref, subscribers} when map_size(subscribers) == 0 ->
        {:noreply, go_absent(%{state | subscribers: subscribers})}

      {_, subscribers} ->
        {:noreply, %{state | subscribers: subscribers}}
    end
  end

  # The Member did not return within the grace: the running work is
  # cancelled, the Workspace discarded and the Household's slot released.
  defp do_info({:grace_expired, ref}, %{grace_ref: ref} = state) do
    state = cancel_run(state)
    _ = PlanningRepo.expire_session(state.account_id, state.session_id)
    emit(state, %{"type" => "session_ended"})
    {:stop, :normal, %{state | session_id: nil, grace_ref: nil}}
  end

  defp do_info({:grace_expired, _stale}, state), do: {:noreply, state}

  # A running turn is never cut: the idle time restarts when it ends.
  defp do_info({:idle_expired, ref}, %{idle_ref: ref, task: %Task{}} = state),
    do: {:noreply, touch(state)}

  # The Member did nothing for the idle time: the session ends like an
  # expired grace, discarding its Workspace and releasing the slot.
  defp do_info({:idle_expired, ref}, %{idle_ref: ref} = state) do
    _ = PlanningRepo.expire_session(state.account_id, state.session_id)
    emit(state, %{"type" => "session_ended"})
    {:stop, :normal, %{state | session_id: nil, idle_ref: nil}}
  end

  defp do_info({:idle_expired, _stale}, state), do: {:noreply, state}

  defp do_info(:renew_lease, state) do
    case renew_lease(state) do
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

  defp do_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    interrupted? = state.task != nil
    state = cancel_run(state)

    cond do
      state.session_id == nil ->
        :ok

      reason == :normal ->
        _ = PlanningRepo.expire_session(state.account_id, state.session_id)
        emit(state, %{"type" => "session_ended"})

      # A shutdown (server restart) or a crash keeps the Planning Session
      # recoverable for its grace; its running request is not resumed.
      true ->
        _ = persist(state, interrupted?)
        :ok
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

  # A confirmed Proposal ends this session only when it is this session's
  # own current one (a lost acknowledgement retried in the same process). A
  # replay of a Proposal from an earlier, already ended session of the
  # Household is answered with its summary and leaves this session running.
  defp own_proposal?(%{workspace: %{proposal: %{"proposal_id" => id}}}, id), do: true
  defp own_proposal?(_state, _proposal_id), do: false

  defp confirm_current(%{task: %Task{}} = state, _proposal_id),
    do: {:reply, {:error, :busy}, state}

  defp confirm_current(%{subscribers: subscribers} = state, _proposal_id)
       when map_size(subscribers) == 0,
       do: {:reply, {:error, :member_absent}, state}

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
      household: household,
      clock: state.clock,
      recipe_drafts: state.workspace.recipe_drafts,
      absence_exceptions: state.workspace.absence_exceptions,
      # The guests the shown Proposal was scaled to (issue #152).
      guests: Map.get(state.workspace, :guests, %{}),
      # The Session Brands the shown Proposal was built with.
      session_brands: Map.get(state.workspace, :session_brands, %{})
    }

    with {:valid, meals} <- ProposalValidator.validate(Proposal.meals(shown), ctx),
         {current, purchase} = Proposal.build(meals, ctx),
         true <- Proposal.same_content?(current, shown) || {:stale, current},
         :ok <- approved(state.workspace, shown) do
      save(state, shown, purchase)
    else
      {:invalid, violations} ->
        {:reply, {:error, :revalidation_conflict},
         revalidation_conflict(state, shown, violations)}

      # Only the affected parts changed: the same meals are shown again,
      # recalculated, as a new Proposal the Member is asked to confirm.
      {:stale, current} ->
        emit(state, current)
        state = %{state | workspace: show(state.workspace, current)}
        {:reply, {:error, :stale_proposal}, state}

      {:error, :approval_required} = error ->
        {:reply, error, state}
    end
  end

  # A Proposal with Deviations is confirmed only with the Deviation Approval
  # of that exact Proposal: same identity, same Deviations.
  defp approved(_workspace, %{"status" => "valid"}), do: :ok

  defp approved(
         %{deviation_approval: %{proposal_id: id, deviations: deviations}},
         %{"proposal_id" => id, "deviations" => deviations}
       ),
       do: :ok

  defp approved(_workspace, _shown), do: {:error, :approval_required}

  # Approvals are human-owned: the Workspace a turn returns never sets or
  # changes them.
  @human_owned [:deviation_approval, :absence_exceptions]

  defp adopt_workspace(current, from_turn) do
    from_turn
    |> Map.merge(Map.take(current, @human_owned))
    |> void_stale_approval()
  end

  defp show(workspace, proposal), do: void_stale_approval(%{workspace | proposal: proposal})

  # Any change to the shown Proposal voids its Deviation Approval.
  defp void_stale_approval(
         %{deviation_approval: %{proposal_id: id}, proposal: %{"proposal_id" => id}} = workspace
       ),
       do: workspace

  defp void_stale_approval(workspace), do: %{workspace | deviation_approval: nil}

  # Recipe Drafts the Proposal uses are saved with it as AI-created
  # Household Recipes; unused Drafts are discarded with the Workspace.
  defp save(state, shown, purchase) do
    meals = Proposal.meals(shown)

    recipes =
      meals
      |> Enum.map(& &1.recipe_id)
      |> Enum.uniq()
      |> Enum.flat_map(&List.wrap(state.workspace.recipe_drafts[&1]))

    attrs = %{
      confirmation_id: shown["proposal_id"],
      account_id: state.account_id,
      session_id: state.session_id,
      membership_id: state.membership_id,
      user_id: state.user_id,
      range: state.range,
      meals: meals,
      recipes: recipes,
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

    state = %{state | workspace: show(Workspace.void_proposal(state.workspace), nil)}

    if state.consent? and state.pending_limit == nil do
      notice = %{role: :user, content: conflict_notice(violations)}
      start_turn(%{state | messages: state.messages ++ [notice]})
    else
      state
    end
  end

  # An Absence Exception names one Restriction of one Member that Member
  # holds, for meals of the Planning Range and its slots.
  defp absence_exception(state, %{member_id: member_id, restriction: restriction, meals: meals})
       when is_list(meals) and meals != [] do
    member = Enum.find(state.household.members, &(&1.id == member_id))
    holds? = member != nil and restriction in member.restrictions

    if holds? and Enum.all?(meals, &in_range?(state, &1)) and Enum.uniq(meals) == meals,
      do: {:ok, %{member_id: member_id, restriction: restriction, meals: meals}},
      else: :error
  end

  defp absence_exception(_state, _exception), do: :error

  defp in_range?(%{range: {from_date, to_date}, slots: slots}, {%Date{} = date, slot}),
    do:
      Date.compare(date, from_date) != :lt and Date.compare(date, to_date) != :gt and
        slot in slots

  defp in_range?(_state, _meal), do: false

  # Code-authored: the Member approved it, so the agent can present again.
  defp absence_notice(meals) do
    "[Absence Exception approved by the Member] One household Restriction is lifted for " <>
      "these meals only: " <>
      Jason.encode!(meals) <>
      ". present_proposal now accepts them where only that Restriction blocked them."
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

  defp save_dictated(state, draft) do
    Repo.transaction(fn ->
      case RecipeDraft.persist(Repo, draft, state.account_id, state.user_id) do
        {:ok, recipe} -> recipe
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, recipe} ->
        saved = %{
          recipe_id: recipe.id,
          name: recipe.name,
          origin: RecipeOrigin.label(recipe.source)
        }

        emit(state, %{
          "type" => "recipe_saved",
          "recipe_id" => saved.recipe_id,
          "name" => saved.name,
          "origin" => saved.origin
        })

        state = update_in(state.workspace.recipe_drafts, &Map.delete(&1, draft.id))
        {:reply, {:ok, saved}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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
      present?: fn -> :atomics.get(presence, 1) == 1 end,
      tool_context: %{
        account_id: state.account_id,
        session_id: state.session_id,
        range: state.range,
        slots: state.slots,
        household: state.household,
        optimizer: state.optimizer,
        recipe_search: state.recipe_search,
        price_scraper: state.price_scraper,
        clock: state.clock,
        workspace: state.workspace
      }
    }

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        ref = receive(do: ({^holder, ref} -> ref))
        emit_fun = fn event -> send(session, {:agent_event, ref, event}) end
        checkpoint = fn model_state -> send(session, {:model_state, ref, seal(model_state)}) end
        on_os_process = fn event -> send(session, {:os_process, ref, event}) end
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

        tool_context =
          turn.tool_context
          |> Map.put(:emit, emit_fun)
          |> Map.put(:bounds, bounds)
          |> Map.update!(:optimizer, &with_os_process_hook(&1, on_os_process))
          # A tool checkpoints a Workspace change before showing it to the
          # Member (a Session Brand), so a deadline cut cannot lose it.
          |> Map.put(:report_workspace, fn workspace ->
            send(session, {:workspace, ref, workspace})
          end)

        result =
          %{turn | tool_context: tool_context, model_state: unseal(turn.model_state)}
          |> Map.put(:emit, emit_fun)
          |> Map.put(:bounds, bounds)
          |> Map.put(:checkpoint, checkpoint)
          |> Map.put(:report_allowance, report_allowance)
          |> Map.put(:on_workspace, fn workspace ->
            send(session, {:workspace, ref, workspace})
          end)
          |> Loop.run()

        %{result | model_state: seal(result.model_state)}
      end)

    send(task.pid, {holder, task.ref})
    deadline_ref = Process.send_after(self(), {:deadline, task.ref}, state.deadline_ms)
    %{state | task: task, deadline_ref: deadline_ref}
  end

  defp stop_turn(state), do: state |> halt_turn() |> elem(0)

  # Kills the turn and also returns the shutdown result, so a caller can tell
  # a turn that had already replied from one that was cut off.
  defp halt_turn(%{task: task} = state) do
    shutdown = Task.shutdown(task, :brutal_kill)

    state =
      state
      |> adopt_checkpoints(task.ref)
      |> adopt_finished_turn(shutdown)
      |> kill_os_processes()
      |> clear_turn()

    {state, shutdown}
  end

  # A turn that replied before the shutdown already settled: Task.shutdown
  # consumed its reply, so keep its messages, model state and Workspace.
  defp adopt_finished_turn(state, {:ok, result}),
    do: %{
      state
      | model_state: result.model_state,
        messages: result.messages,
        workspace: adopt_workspace(state.workspace, result.workspace),
        allowance: result.allowance
    }

  defp adopt_finished_turn(state, _shutdown), do: state

  # The task is dead, so everything it sent is already queued: adopt the
  # latest model state (paid usage stays counted), allowance (counted
  # iterations stay counted) and Workspace, learn every optimizer process it
  # started, and drop its late events.
  defp adopt_checkpoints(state, ref) do
    receive do
      {:model_state, ^ref, sealed} ->
        adopt_checkpoints(%{state | model_state: sealed}, ref)

      {:allowance, ^ref, allowance} ->
        adopt_checkpoints(%{state | allowance: allowance}, ref)

      {:workspace, ^ref, workspace} ->
        adopt_checkpoints(adopt_workspace_checkpoint(state, workspace), ref)

      {:os_process, ^ref, event} ->
        adopt_checkpoints(track_os_process(state, event), ref)

      {:agent_event, ^ref, _late} ->
        adopt_checkpoints(state, ref)
    after
      0 -> state
    end
  end

  defp adopt_workspace_checkpoint(state, workspace),
    do: %{state | workspace: adopt_workspace(state.workspace, workspace)}

  defp track_os_process(state, {:started, os_pid}),
    do: %{state | os_pids: MapSet.put(state.os_pids, os_pid)}

  defp track_os_process(state, {:closed, os_pid}),
    do: %{state | os_pids: MapSet.delete(state.os_pids, os_pid)}

  defp track_os_process(state, _event), do: state

  # Synchronous: returns once every optimizer process of the halted turn is
  # gone, so nothing it started can still run when the session replies.
  defp kill_os_processes(state) do
    Enum.each(state.os_pids, fn os_pid ->
      case OsProcess.kill(os_pid) do
        :ok -> :ok
        {:error, reason} -> Logger.error("planning agent optimizer kill: #{inspect(reason)}")
      end
    end)

    %{state | os_pids: MapSet.new()}
  end

  # The session learns every OS process first; a hook configured on the
  # optimizer still runs after it.
  defp with_os_process_hook({module, opts}, hook) when is_list(opts) do
    chained =
      case Keyword.get(opts, :on_os_process) do
        configured when is_function(configured, 1) ->
          fn event ->
            hook.(event)
            configured.(event)
          end

        _ ->
          hook
      end

    {module, Keyword.put(opts, :on_os_process, chained)}
  end

  defp with_os_process_hook(module, hook) when is_atom(module) and module != nil,
    do: {module, [on_os_process: hook]}

  defp with_os_process_hook(optimizer, _hook), do: optimizer

  # A running turn interrupted by Stop, Cancel, a lost lock or shutdown.
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

  # A cap or ceiling that is never extended is exhausted (issue #154): the
  # agent's part of the session ends gracefully. The Member gets a message
  # and the latest Proposal, both rendered by code, and no more turns start.
  defp finish_run(state, {:exhausted, limit}) do
    state = %{state | exhausted: limit}
    emit(state, budget_exhausted_event(state))
    emit(state, %{"type" => "run_finished", "outcome" => "partial"})
    state
  end

  # The Member left while the run was working: no new model call started.
  defp finish_run(state, {:interrupted, _reason}) do
    emit(state, %{"type" => "run_finished", "outcome" => "interrupted"})
    state
  end

  defp finish_run(state, {:failed, reason}) do
    emit(state, %{"type" => "agent_unavailable", "reason" => reason_string(reason)})
    emit(state, %{"type" => "run_finished", "outcome" => "failure"})
    state
  end

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason), do: "provider_error"

  defp budget_exhausted_event(state) do
    proposal = state.workspace.proposal

    message =
      if proposal,
        do:
          "This planning session has used up what the assistant can spend on it. " <>
            "Your latest proposal is below: you can still confirm it. To keep planning, " <>
            "start a new planning session.",
        else:
          "This planning session has used up what the assistant can spend on it. " <>
            "Start a new planning session to keep planning."

    %{
      "type" => "session_budget_exhausted",
      "limit" => state.exhausted,
      "message" => message,
      "proposal" => proposal
    }
  end

  # An exhausted session without a Proposal holds nothing the Member could
  # still act on: it ends at once and releases the Household's slot, so a
  # new Planning Session can start. With a Proposal it stays open for the
  # human actions on it (confirm, approve, cancel) until its idle expiry.
  defp after_run(%{exhausted: nil} = state), do: {:noreply, state}

  defp after_run(%{workspace: %{proposal: proposal}} = state) when proposal != nil,
    do: {:noreply, state}

  defp after_run(state) do
    _ = PlanningRepo.expire_session(state.account_id, state.session_id)
    emit(state, %{"type" => "session_ended"})
    {:stop, :normal, %{state | session_id: nil}}
  end

  defp allowance(args, saved) do
    fresh =
      Allowance.new(args.max_iterations, max_session_iterations: args.max_session_iterations)

    if saved, do: Allowance.restore(saved.allowance, fresh), else: fresh
  end

  # A turn that ends restarts the idle time: the Member reads its result.
  defp clear_turn(state) do
    if state.deadline_ref, do: Process.cancel_timer(state.deadline_ref)
    touch(%{state | task: nil, deadline_ref: nil})
  end

  # ===========================================================================
  # Idle expiry
  # ===========================================================================

  # Reads that change nothing are not Member activity.
  @passive_calls [:info, :current_proposal]

  defp member_activity(message, state) when message in @passive_calls, do: state
  defp member_activity(_message, state), do: touch(state)

  defp touch(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    ref = make_ref()
    timer = Process.send_after(self(), {:idle_expired, ref}, state.idle_ms)
    %{state | idle_ref: ref, idle_timer: timer}
  end

  # ===========================================================================
  # Recoverable storage
  # ===========================================================================

  @snapshot_version 1

  # The durable part of the state: what a restart needs to restore the
  # Planning Session. The Household context is reloaded instead, and the
  # model adapter keeps only its recoverable part (spend), never credentials.
  defp snapshot(state, running?) do
    %{
      version: @snapshot_version,
      user_id: state.user_id,
      membership_id: state.membership_id,
      role: state.role,
      range: state.range,
      slots: state.slots,
      messages: state.messages,
      workspace: state.workspace,
      allowance: state.allowance,
      pending_limit: state.pending_limit,
      exhausted: state.exhausted,
      model: Model.recoverable(state.model, unseal(state.model_state)),
      running?: running?
    }
  end

  defp persist(state), do: persist(state, state.task != nil)

  defp persist(%{session_id: nil} = state, _running?), do: state

  defp persist(state, running?) do
    snapshot = snapshot(state, running?)
    hash = :erlang.phash2(snapshot)

    if hash == state.persisted do
      state
    else
      binary = :erlang.term_to_binary(snapshot)

      case PlanningRepo.save_recovery(state.account_id, state.session_id, binary) do
        :ok -> %{state | persisted: hash}
        {:error, :not_active} -> state
      end
    end
  rescue
    # Storage being unavailable never stops the session; the next change
    # retries the write.
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      Logger.warning("planning agent snapshot not stored: #{Exception.message(error)}")
      state
  end

  defp decode_snapshot(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{version: @snapshot_version} = saved -> {:ok, saved}
      _other -> {:error, :no_session}
    end
  rescue
    ArgumentError -> {:error, :no_session}
  end

  # A request running when the server stopped is reconciled, not replayed:
  # the agent is told it was interrupted and waits for the Member.
  defp recovered_messages(%{running?: true, messages: messages}),
    do: messages ++ [%{role: :user, content: recovery_notice()}]

  defp recovered_messages(%{messages: messages}), do: messages

  defp recovery_notice do
    "[Session recovered] The server restarted while the previous request was running. " <>
      "That request was not resumed and nothing it did beyond the current Workspace was kept. " <>
      "Wait for the Member's next message; check the Workspace with get_workspace before acting."
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
      state = %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
      return(state)
    end
  end

  # The Member is back within the grace: the expiry is cancelled and the
  # lease covers the next grace again.
  defp return(%{grace_ref: nil} = state), do: state

  defp return(state) do
    Process.cancel_timer(state.grace_ref)
    state = %{state | grace_ref: nil, grace_deadline: nil}
    _ = renew_lease(state)
    state
  end

  # The last subscriber is gone: the grace starts and the lease is fixed to
  # its deadline, so the slot is held exactly that long, also across a
  # restart.
  defp go_absent(state) do
    :atomics.put(state.presence, 1, 0)
    deadline = DateTime.add(DateTime.utc_now(), state.grace_ms, :millisecond)
    ref = make_ref()
    Process.send_after(self(), {:grace_expired, ref}, state.grace_ms)
    state = %{state | grace_ref: ref, grace_deadline: deadline}
    _ = renew_lease(state)
    state
  end

  defp renew_lease(state) do
    until = state.grace_deadline || present_lease(state.grace_ms)
    PlanningRepo.renew_lease(state.account_id, state.session_id, until)
  end

  defp present_lease(grace_ms),
    do: DateTime.add(DateTime.utc_now(), max(grace_ms, @min_lease_ms), :millisecond)

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
    "recipe_draft" =>
      ~w(recipe_id name origin draft servings slots ingredients steps nutrition cost),
    "optimizer_failed" => ~w(reason),
    "session_brand_changed" => ~w(ingredient brand source previous_brand previous_source),
    "consent_required" => [],
    "limit_reached" => ~w(limit requires_authorization),
    "agent_unavailable" => ~w(reason),
    "session_budget_exhausted" => ~w(limit message proposal),
    "turn_completed" => [],
    "run_finished" => ~w(outcome),
    "stopped" => [],
    "session_cancelled" => [],
    "session_ended" => [],
    "recipe_saved" => ~w(recipe_id name origin),
    "proposal_confirmed" => ~w(proposal_id meals_count shopping_lines_count),
    "proposal_invalidated" => ~w(proposal_id reason violations),
    "confirmation_unresolved" => ~w(proposal_id),
    "deviations_approved" => ~w(proposal_id deviations),
    "absence_exception_approved" => ~w(meals),
    "session_recovered" => ~w(interrupted)
  }
  @meal_fields ~w(date slot recipe_id name origin draft diners guests batches)

  # Streaming carries progress only: known event types with known fields.
  # Anything else, such as raw tool output or model reasoning, is dropped.
  defp sanitize(%{"type" => type} = event) when is_map_key(@event_fields, type) do
    event
    |> Map.take(["type" | Map.fetch!(@event_fields, type)])
    |> Map.replace_lazy("meals", fn meals ->
      Enum.map(List.wrap(meals), &Map.take(&1, @meal_fields))
    end)
    |> Map.replace_lazy("proposal", fn proposal -> proposal && sanitize(proposal) end)
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

  defp lock(attrs, from_date, to_date, grace_ms, start_limit) do
    PlanningRepo.create_household_session(
      attrs.account_id,
      %{
        range_from: from_date,
        range_to: to_date,
        lock_owner_user_id: attrs.user_id,
        lock_owner_membership_id: attrs.membership_id,
        lease_expires_at: present_lease(grace_ms),
        agent: true
      },
      start_limit: start_limit
    )
  end

  # The start rate limit is a human decision: without a valid one no
  # Planning Session starts.
  defp start_limit({max_starts, window_seconds} = limit)
       when is_integer(max_starts) and max_starts > 0 and is_integer(window_seconds) and
              window_seconds > 0,
       do: {:ok, limit}

  defp start_limit(_limit), do: {:error, :spend_caps_unconfigured}

  defp config(key) do
    :meal_planner_api
    |> Application.get_env(:planning_agent, [])
    |> Keyword.get(key)
  end
end
