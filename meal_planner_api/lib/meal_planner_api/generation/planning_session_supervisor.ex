defmodule MealPlannerApi.Generation.PlanningSessionSupervisor do
  @moduledoc """
  DynamicSupervisor for `PlanningSessionServer` instances.

  One session process per active `PlanningSession`. Children are
  `:temporary` — when a session transitions to a terminal status, the
  process is expected to terminate; the audit row remains in
  `planning_sessions` regardless.

  ## Public API

    * `start_link/1` — supervisor child spec; takes an optional `:name`
      opt (default `__MODULE__`). Tests override `name: nil` to keep
      the test supervisor anonymous so it does not collide with the
      production tree's registered instance.
    * `start_session/4` — convenience helper that generates a
      placeholder `session_id`, starts a `PlanningSessionServer` under
      this supervisor, and calls `start_session/5` on the new pid.
      Designed for PR4 channel code that wants to express
      "start a planning session for this account" in one call.

  Children are reachable only via the pid returned by
  `DynamicSupervisor.start_child/2`; no Registry lookup.
  """

  use DynamicSupervisor

  alias MealPlannerApi.Generation.PlanningSessionServer

  @doc """
  Starts the supervisor under the application's tree.

  ## Opts

    * `:name` — registered process name. Defaults to `__MODULE__`
      (production). Tests typically pass `name: nil` to keep the
      instance anonymous.
  """
  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    DynamicSupervisor.start_link(__MODULE__, [], name: name)
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new session process and registers the session row.

  Generates a `session_id` for the in-memory process identity (the
  canonical row id comes from `PlanningRepo.create_session/2` once
  the row is inserted), starts a `PlanningSessionServer` under this
  supervisor, and delegates to `PlanningSessionServer.start_session/5`.

  ## Opts

    * `:channel_pid` — the calling channel's pid. The server
      `Process.monitor`s it; on abnormal exit the row transitions
      to `:lost_lock` and `session_lost_lock` is broadcast.

  Returns:

    * `{:ok, %{session_id: id, pid: pid}}` — the session row is
      `:active` in the DB and the channel can route intents to
      `pid`.
    * `{:error, :subscription_required | :overlapping_range | term()}`
      — same shape as `PlanningSessionServer.start_session/5`.
  """
  @spec start_session(
          Ecto.UUID.t(),
          pos_integer(),
          Ecto.UUID.t(),
          {Date.t(), Date.t()},
          keyword()
        ) ::
          {:ok, %{session_id: Ecto.UUID.t(), pid: pid()}}
          | {:error, :subscription_required | :overlapping_range | term()}
  def start_session(account_id, user_id, membership_id, range, opts \\ []) do
    session_id = Ecto.UUID.generate()
    channel_pid = Keyword.get(opts, :channel_pid)

    child_spec =
      PlanningSessionServer.child_spec(
        account_id: account_id,
        session_id: session_id,
        owner_user_id: user_id,
        owner_membership_id: membership_id,
        owner_channel_pid: channel_pid
      )

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        case PlanningSessionServer.start_session(
               pid,
               account_id,
               user_id,
               membership_id,
               range
             ) do
          {:ok, %{session_id: db_session_id}} -> {:ok, %{session_id: db_session_id, pid: pid}}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end
end
