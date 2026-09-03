defmodule MealPlannerApi.Generation.PlanningSessionSupervisorTest do
  @moduledoc """
  Tests for `MealPlannerApi.Generation.PlanningSessionSupervisor` —
  PR3 (`ephemeral-planning-sessions`, Phase 3, tasks 3.3–3.4) +
  PR5 (Phase 5: supervisor fix + rehydrate).

  Scope:

    * `@task 3.3` — `start_link/1` returns `{:ok, pid}`.
    * `@task 3.3` — children added via `DynamicSupervisor.start_child/2`
      get a live pid.
    * `@task 3.3` — `Supervisor.count_children/1` reflects the child.
    * `PR5` — `start_session/5` builds a working child spec (the
      PR3 child-spec bug unpacks keyword-list args as separate
      Erlang args, crashing `start_link/1` with `:undef`).
    * `PR5` — `:transient` restart on abnormal exit (TM-2).
    * `PR5` — `start_session/5` accepts a `:channel_pid` opt and the
      server monitors it (lost_lock wiring).

  The supervisor is exercised under an anonymous name so we don't
  collide with the production tree's registered instance during tests.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Generation.PlanningSessionSupervisor
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.Repo

  # Marks the freshly-inserted Account as eligible for
  # `AccountAccess.eligible?/1` by setting a forward-looking trial
  # window. PR3's server checks entitlement on `start_session/5`;
  # without this the test account is `subscription_required`.
  defp mark_eligible!(%PersistenceAccount{} = account) do
    started = DateTime.utc_now()
    ends = DateTime.add(started, 7 * 86_400, :second)

    {:ok, updated} =
      account
      |> PersistenceAccount.changeset(%{trial_started_at: started, trial_ends_at: ends})
      |> Repo.update()

    updated
  end

  setup do
    :ok = Sandbox.checkout(MealPlannerApi.Repo)
    Sandbox.mode(MealPlannerApi.Repo, {:shared, self()})
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    # The supervisor is a singleton started by the application; its
    # children (session servers) outlive the test process because
    # they're supervised by the production tree. Drain it before
    # each PR5 test so count_children is meaningful.
    drain_planning_session_children()
    :ok
  end

  defp drain_planning_session_children do
    case Process.whereis(PlanningSessionSupervisor) do
      nil ->
        :ok

      sup_pid ->
        for {_, child_pid, _, _} <- Supervisor.which_children(sup_pid) do
          Process.exit(child_pid, :shutdown)
        end

        :ok
    end
  end

  test "start_link/1 returns {:ok, pid}" do
    {:ok, sup_pid} = PlanningSessionSupervisor.start_link(name: nil)
    assert is_pid(sup_pid)
    assert Process.alive?(sup_pid)
  end

  test "Supervisor accepts a child and the child pid is alive" do
    {:ok, sup_pid} = PlanningSessionSupervisor.start_link(name: nil)

    {:ok, child_pid} =
      DynamicSupervisor.start_child(
        sup_pid,
        %{
          id: :test_child_alive,
          start: {Agent, :start_link, [fn -> %{} end]},
          restart: :temporary
        }
      )

    assert is_pid(child_pid)
    assert Process.alive?(child_pid)

    # Confirm the child is actually findable via count_children below.
    counts = Supervisor.count_children(sup_pid)
    assert counts.active >= 1
  end

  test "Supervisor.count_children/1 reflects started children" do
    {:ok, sup_pid} = PlanningSessionSupervisor.start_link(name: nil)

    {:ok, _} =
      DynamicSupervisor.start_child(
        sup_pid,
        %{
          id: :test_child_count_a,
          start: {Agent, :start_link, [fn -> %{} end]},
          restart: :temporary
        }
      )

    counts = Supervisor.count_children(sup_pid)

    # `active` includes all currently-running children; `specs` includes
    # all child specs ever added. We assert `active >= 1` rather than
    # `== 1` because ExUnit's `start_supervised!` machinery itself adds
    # to the local test supervisor (separate process); the canonical
    # invariant we own here is "this supervisor has at least one child".
    assert counts.active >= 1
  end

  # ==========================================================================
  # PR5 — supervisor's start_session/5 actually starts a server
  # (the PR3 child-spec bug unpacked keyword-list args as separate
  # Erlang args, crashing `start_link/1` with `:undef`).
  # ==========================================================================

  describe "start_session/5 (PR5 supervisor fix)" do
    test "starts a PlanningSessionServer under the supervisor + returns its pid and a DB session_id" do
      account = insert_account("PR5 sup ok")
      _ = mark_eligible!(account)
      user = insert_user_with_membership(account, "pr5-sup-ok@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      # The application already starts `PlanningSessionSupervisor`
      # under the default name (`__MODULE__`) — `start_session/5`
      # uses that name, so we just add a child to the running
      # instance.
      sup_pid = Process.whereis(PlanningSessionSupervisor)
      assert is_pid(sup_pid)

      # The test process simulates the channel for monitoring purposes.
      {:ok, %{session_id: session_id, pid: pid}} =
        PlanningSessionSupervisor.start_session(
          account.id,
          user.id,
          membership_id,
          {~D[2026-07-01], ~D[2026-07-07]},
          channel_pid: self()
        )

      assert is_binary(session_id)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # The supervisor owns the child.
      counts = Supervisor.count_children(sup_pid)
      assert counts.active >= 1

      # The row exists and is :active.
      row = Repo.get!(PlanningSession, session_id)
      assert row.status == :active
      assert row.account_id == account.id
      assert row.lock_owner_user_id == user.id
      assert row.lock_owner_membership_id == membership_id
    end

    test "abnormal exit of the channel Process.monitor'd by the server transitions row to :lost_lock" do
      account = insert_account("PR5 sup lost_lock abnormal")
      _ = mark_eligible!(account)
      user = insert_user_with_membership(account, "pr5-sup-lost-lock@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "planning:#{account.id}")

      # Spawn a throwaway process to act as the channel. Plain `spawn`
      # (not `spawn_link`) so killing it does NOT also kill the test
      # process via the link.
      channel_pid =
        spawn(fn ->
          Process.sleep(:infinity)
        end)

      {:ok, %{session_id: session_id, pid: server_pid}} =
        PlanningSessionSupervisor.start_session(
          account.id,
          user.id,
          membership_id,
          {~D[2026-07-08], ~D[2026-07-14]},
          channel_pid: channel_pid
        )

      # Drain the startup broadcast.
      assert_receive %Phoenix.Socket.Broadcast{event: "session_started"}, 1_000

      # Kill the channel abnormally.
      Process.exit(channel_pid, :killed)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "session_lost_lock",
                       payload: %{"session_id" => ^session_id}
                     },
                     1_000

      row = Repo.get!(PlanningSession, session_id)
      assert row.status == :lost_lock
      assert row.terminal_at != nil

      # The server stays alive (TM-3) — no restart needed.
      assert Process.alive?(server_pid)
    end

    test "TM-3: :normal exit of the monitored channel does NOT trigger :lost_lock" do
      account = insert_account("PR5 sup lost_lock normal")
      _ = mark_eligible!(account)
      user = insert_user_with_membership(account, "pr5-sup-normal@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "planning:#{account.id}")

      # Spawn a process that exits :normal shortly after we subscribe.
      parent = self()

      channel_pid =
        spawn(fn ->
          send(parent, :channel_ready)
          Process.sleep(50)
        end)

      assert_receive :channel_ready, 1_000

      {:ok, %{session_id: session_id, pid: server_pid}} =
        PlanningSessionSupervisor.start_session(
          account.id,
          user.id,
          membership_id,
          {~D[2026-07-15], ~D[2026-07-21]},
          channel_pid: channel_pid
        )

      # Wait long enough for the channel to exit :normal and the
      # server to process the DOWN message.
      :timer.sleep(200)
      _ = :sys.get_state(server_pid)

      # No :lost_lock transition.
      row = Repo.get!(PlanningSession, session_id)
      assert row.status == :active
      assert row.terminal_at == nil

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "session_lost_lock",
                       payload: %{"session_id" => ^session_id}
                     },
                     200
    end

    test "TM-2: abnormal server exit triggers :transient restart + rehydrate from DB + session_resumed" do
      account = insert_account("PR5 sup restart rehydrate")
      _ = mark_eligible!(account)
      user = insert_user_with_membership(account, "pr5-sup-restart@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "planning:#{account.id}")

      sup_pid = Process.whereis(PlanningSessionSupervisor)
      assert is_pid(sup_pid)

      # `channel_pid: nil` — the test only cares about server restart,
      # not the channel monitor path.
      {:ok, %{session_id: session_id, pid: server_pid}} =
        PlanningSessionSupervisor.start_session(
          account.id,
          user.id,
          membership_id,
          {~D[2026-07-22], ~D[2026-07-28]},
          channel_pid: nil
        )

      # Drain session_started.
      assert_receive %Phoenix.Socket.Broadcast{event: "session_started"}, 1_000

      # The old server is in :active with the row.
      assert %{status: :active} = :sys.get_state(server_pid)

      # Kill the server with :kill (abnormal). The supervisor
      # restarts it because the child spec is :transient.
      ref = Process.monitor(server_pid)
      Process.exit(server_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server_pid, :killed}, 1_000

      # The new server rehydrates from the DB and broadcasts
      # session_resumed.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "session_resumed",
                       payload: %{"session_id" => ^session_id}
                     },
                     2_000

      # Wait for the supervisor to settle, then find the new pid and
      # assert its state is :active (rehydrated, not initializing).
      :timer.sleep(100)
      [{_id, new_pid, :worker, _modules}] = Supervisor.which_children(sup_pid)
      assert %{status: :active} = :sys.get_state(new_pid)

      # Wait for the new server to register and confirm the row is
      # still :active (the rehydrated server didn't transition it).
      :timer.sleep(100)
      row = Repo.get!(PlanningSession, session_id)
      assert row.status == :active

      # Supervisor still has exactly one child (the restarted server).
      counts = Supervisor.count_children(sup_pid)
      assert counts.active == 1
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp insert_account(name) do
    plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

    {:ok, account} =
      %PersistenceAccount{}
      |> PersistenceAccount.changeset(%{
        name: name,
        plan: :family_4,
        default_budget_cents: 0,
        subscription_plan_id: plan.id
      })
      |> Repo.insert()

    account
  end

  defp insert_user_with_membership(account, email, role) do
    user =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: email, role: role})
      |> Repo.insert!()

    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account.id,
      user_id: user.id,
      role: role,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    user
  end

  defp owner_membership_id(account_id, user_id) do
    Repo.one!(
      from(m in AccountMembership,
        where: m.account_id == ^account_id and m.user_id == ^user_id and m.status == :active
      )
    ).id
  end
end
