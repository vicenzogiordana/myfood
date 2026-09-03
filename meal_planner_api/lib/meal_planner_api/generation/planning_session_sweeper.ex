defmodule MealPlannerApi.Generation.PlanningSession.Sweeper do
  @moduledoc """
  Periodic GenServer that transitions stale `:active` `PlanningSession`
  rows to `:expired`.

  Runs every `:planning_session_sweeper_interval` ms (default 30_000).

  Each tick:

    1. Finds `:active` sessions whose `lease_expires_at < now()`.
    2. For each candidate, opens a transaction that locks the row with
       `FOR UPDATE SKIP LOCKED`. This makes the sweeper safe to run
       concurrently with `cancel_session/4` — both serialize on the
       row, and at most one of them can transition a given session to a
       terminal status.
    3. Calls `PlanningRepo.expire_session/2` on the locked row and
       broadcasts `session_expired` on `planning:<account_id>`.

  Skips rows whose status has already moved to a terminal value
  (`:cancelled`, `:committed`, `:lost_lock`, `:expired`) since the
  candidate scan ran. The `FOR UPDATE SKIP LOCKED` row-lock is what
  guarantees we don't race with a concurrent cancel.
  """

  use GenServer

  import Ecto.Query, warn: false

  alias MealPlannerApi.Persistence.Planning.PlanningException
  alias MealPlannerApi.Persistence.Planning.PlanningMessage
  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.Repo

  @default_interval 30_000

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts the sweeper.

  ## Opts

    * `:interval` — tick interval in ms. Overrides
      `Application.get_env(:meal_planner_api, :planning_session_sweeper_interval)`.
    * `:name` — registered process name (default `__MODULE__`). Tests
      override to keep instances anonymous.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    interval =
      Keyword.get(opts, :interval) ||
        Application.get_env(
          :meal_planner_api,
          :planning_session_sweeper_interval,
          @default_interval
        )

    schedule_tick(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    sweep_once()
    schedule_tick(state.interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ===========================================================================
  # Sweep tick (private)
  # ===========================================================================

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp sweep_once do
    now = DateTime.utc_now()

    candidates =
      from(s in PlanningSession,
        where: s.status == :active and s.lease_expires_at < ^now,
        select: %{id: s.id, account_id: s.account_id}
      )
      |> Repo.all()

    Enum.each(candidates, fn %{id: session_id, account_id: account_id} ->
      try_expire(account_id, session_id)
    end)
  end

  # Locks the candidate row with `FOR UPDATE SKIP LOCKED`. If the row is
  # already terminal (someone else cancelled it first) or another
  # transaction holds the lock, the locked query returns `nil` and we
  # skip without broadcasting.
  defp try_expire(account_id, session_id) do
    result =
      Repo.transaction(fn ->
        locked =
          from(s in PlanningSession,
            where: s.id == ^session_id and s.status == :active,
            lock: "FOR UPDATE SKIP LOCKED"
          )
          |> Repo.one()

        case locked do
          %PlanningSession{} ->
            {:ok, _expired} =
              locked
              |> Ecto.Changeset.change(%{
                status: :expired,
                terminal_at: DateTime.utc_now()
              })
              |> Repo.update()

            delete_children(session_id)
            :ok

          nil ->
            :skipped
        end
      end)

    case result do
      {:ok, :ok} ->
        broadcast_expired(account_id, session_id)

      _ ->
        :ok
    end
  end

  defp delete_children(session_id) do
    Repo.delete_all(from(m in PlanningMessage, where: m.session_id == ^session_id))
    Repo.delete_all(from(e in PlanningException, where: e.session_id == ^session_id))
    :ok
  end

  defp broadcast_expired(account_id, session_id) do
    Phoenix.Channel.Server.broadcast!(
      MealPlannerApi.PubSub,
      "planning:#{account_id}",
      "session_expired",
      %{"session_id" => session_id}
    )
  end
end
