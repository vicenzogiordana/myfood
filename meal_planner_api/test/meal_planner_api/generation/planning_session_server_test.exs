defmodule MealPlannerApi.Generation.PlanningSessionServerTest do
  @moduledoc """
  Integration tests for `MealPlannerApi.Generation.PlanningSessionServer` —
  PR3 (`ephemeral-planning-sessions`, Phase 3, tasks 3.1–3.2 + 3.7–3.8).

  Spec coverage:

    * `@task 3.1` — `start_link/1` returns `{:ok, pid}` and the GenServer
      is alive.
    * `@task 3.2` — `start_session/5` happy path: returns
      `{:ok, %{session_id: id}}` and writes a `:active` `planning_sessions`
      row.
    * `@task 3.2` — overlapping range on the same account returns
      `{:error, :overlapping_range}` (no second row written).
    * `@task 3.2` — ineligible Account returns
      `{:error, :subscription_required}` (no row written).
    * `@task 3.7` — `:DOWN` with abnormal reason (e.g. `:killed`)
      transitions the row to `:lost_lock` AND broadcasts
      `session_lost_lock` on `planning:<account_id>`.
    * `@task 3.7` — `:DOWN` with `:normal` / `:shutdown` reason MUST NOT
      transition (clean exit path).

  Entitlement is stubbed via the `:check_account_eligible_fn` opt that
  the server exposes for test injection; this avoids `Mox` overhead for
  a single boolean. Production callers use the default
  `AccountAccess.eligible?/1`.

  Broadcasts are observed via `Phoenix.PubSub.subscribe/2` (the same
  path the production channel will use in PR4).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Generation.PlanningSessionServer
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.PubSub
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(MealPlannerApi.Repo)
    # `async: false` here lets us share the test process's DB connection with
    # any supervised GenServer (`PlanningSessionServer`) — same model as
    # the existing `Generation.ServerTest`.
    Sandbox.mode(MealPlannerApi.Repo, {:shared, self()})
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    :ok
  end

  # ---------------------------------------------------------------------------
  # @task 3.1 — start_link/1 + lifecycle
  # ---------------------------------------------------------------------------

  describe "start_link/1 — supervisor child spec (@task 3.1)" do
    test "returns {:ok, pid} and the GenServer is alive" do
      pid =
        start_session_server!(
          account_id: Ecto.UUID.generate(),
          check_account_eligible_fn: fn _ -> true end
        )

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Drain any pending messages before tearing down.
      _ = :sys.get_state(pid)
    end

    test "accepts an explicit :session_id opt and stores it in state" do
      session_id = Ecto.UUID.generate()

      pid =
        start_session_server!(
          account_id: Ecto.UUID.generate(),
          session_id: session_id,
          check_account_eligible_fn: fn _ -> true end
        )

      assert %{session_id: ^session_id} = :sys.get_state(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # @task 3.2 — start_session/5 happy path
  # ---------------------------------------------------------------------------

  describe "start_session/5 — happy path (@task 3.2)" do
    test "returns {:ok, %{session_id: id}} and writes a :active planning_sessions row" do
      account = insert_account("PR3 happy")
      user = insert_user_with_membership(account, "pr3-happy@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      pid =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      # Subscribe BEFORE start_session so we don't miss session_started.
      topic = "planning:#{account.id}"
      :ok = Phoenix.PubSub.subscribe(PubSub, topic)

      assert {:ok, %{session_id: session_id}} =
               PlanningSessionServer.start_session(
                 pid,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-01], ~D[2026-03-08]}
               )

      assert is_binary(session_id)

      # The row is in the DB and the entitlement-bearing fields match.
      row = Repo.get!(PlanningSession, session_id)
      assert row.status == :active
      assert row.account_id == account.id
      assert row.range_from == ~D[2026-03-01]
      assert row.range_to == ~D[2026-03-08]
      assert row.lock_owner_user_id == user.id
      assert row.lock_owner_membership_id == membership_id
      assert row.started_at != nil
      assert row.lease_expires_at != nil

      # Broadcast is emitted on the planning:<account_id> topic.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "session_started",
                       payload: %{"session_id" => ^session_id}
                     },
                     1_000
    end
  end

  # ---------------------------------------------------------------------------
  # @task 3.2 — overlapping range rejection
  # ---------------------------------------------------------------------------

  describe "start_session/5 — overlapping range rejected (@task 3.2)" do
    test "a second session overlapping the first returns {:error, :overlapping_range}" do
      account = insert_account("PR3 overlap")
      user = insert_user_with_membership(account, "pr3-overlap@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      # First session lands.
      pid1 =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      assert {:ok, %{session_id: first_id}} =
               PlanningSessionServer.start_session(
                 pid1,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-01], ~D[2026-03-08]}
               )

      assert first_id != nil

      # Second server (separate process; orchestrator simulates another
      # member starting a parallel planning run).
      pid2 =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      assert {:error, :overlapping_range} =
               PlanningSessionServer.start_session(
                 pid2,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-05], ~D[2026-03-12]}
               )

      # Only the first session row exists on the account.
      count =
        Repo.one!(
          from(s in PlanningSession,
            where: s.account_id == ^account.id,
            select: count(s.id)
          )
        )

      assert count == 1
    end

    test "two distinct non-overlapping ranges on the same account both succeed (spec triangulation)" do
      account = insert_account("PR3 coexist")
      user = insert_user_with_membership(account, "pr3-coexist@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      pid1 =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      assert {:ok, %{session_id: first_id}} =
               PlanningSessionServer.start_session(
                 pid1,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-01], ~D[2026-03-08]}
               )

      pid2 =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      assert {:ok, %{session_id: second_id}} =
               PlanningSessionServer.start_session(
                 pid2,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-15], ~D[2026-03-22]}
               )

      assert first_id != second_id

      # Both rows remain :active concurrently.
      rows =
        Repo.all(
          from(s in PlanningSession,
            where: s.account_id == ^account.id,
            order_by: [asc: s.range_from]
          )
        )

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.status == :active))
    end
  end

  # ---------------------------------------------------------------------------
  # @task 3.2 — ineligible Account refused
  # ---------------------------------------------------------------------------

  describe "start_session/5 — ineligible Account refused (@task 3.2)" do
    test "an Account whose entitlement check returns false gets {:error, :subscription_required} and no row written" do
      account = insert_account("PR3 ineligible")
      user = insert_user_with_membership(account, "pr3-ineligible@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      pid =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> false end
        )

      assert {:error, :subscription_required} =
               PlanningSessionServer.start_session(
                 pid,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-01], ~D[2026-03-08]}
               )

      # No row was inserted.
      count =
        Repo.one!(
          from(s in PlanningSession,
            where: s.account_id == ^account.id,
            select: count(s.id)
          )
        )

      assert count == 0

      # Server stays in :initializing — never moved to :active.
      state = :sys.get_state(pid)
      assert state.status == :initializing
    end
  end

  # ---------------------------------------------------------------------------
  # @task 3.2 — apply_intent/3 (typed-intent boundary integration at the GS)
  # ---------------------------------------------------------------------------

  describe "apply_intent/3 — typed-intent boundary (@task 3.2)" do
    test "an accepted intent stores it in state and replies :ok" do
      account = insert_account("PR3 apply_intent ok")
      user = insert_user_with_membership(account, "pr3-intent-ok@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      pid =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      assert {:ok, %{session_id: _session_id}} =
               PlanningSessionServer.start_session(
                 pid,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-01], ~D[2026-03-08]}
               )

      intent = %{
        kind: :change_constraints,
        payload: %{budget_cents: 8_000}
      }

      assert {:ok, ^intent} = PlanningSessionServer.apply_intent(pid, "ignored", intent)

      state = :sys.get_state(pid)
      assert state.pending_intent == intent
    end

    test "a forbidden-key intent is rejected without state mutation" do
      account = insert_account("PR3 apply_intent forbidden")
      user = insert_user_with_membership(account, "pr3-intent-forbidden@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      pid =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      assert {:ok, %{session_id: _}} =
               PlanningSessionServer.start_session(
                 pid,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-01], ~D[2026-03-08]}
               )

      bad_intent = %{
        kind: :change_constraints,
        payload: %{recipe_id: 42}
      }

      assert {:error, :forbidden_intent} =
               PlanningSessionServer.apply_intent(pid, "ignored", bad_intent)

      state = :sys.get_state(pid)
      # Earlier accepted intent is preserved (forbidden one was rejected).
      assert state.pending_intent == nil
    end
  end

  # ---------------------------------------------------------------------------
  # @task 3.7 + 3.8 — handle_info({:DOWN, ...}) lost_lock transition
  # ---------------------------------------------------------------------------

  describe "handle_info({:DOWN, ...}) — lost_lock transition (@task 3.7 / 3.8)" do
    test "abnormal DOWN reason transitions row to :lost_lock and broadcasts session_lost_lock" do
      account = insert_account("PR3 lost_lock abnormal")
      user = insert_user_with_membership(account, "pr3-lost-lock@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      pid =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      # Subscribe BEFORE start_session so we can drain session_started.
      topic = "planning:#{account.id}"
      :ok = Phoenix.PubSub.subscribe(PubSub, topic)

      assert {:ok, %{session_id: session_id}} =
               PlanningSessionServer.start_session(
                 pid,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-01], ~D[2026-03-08]}
               )

      # Drain the startup broadcast.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "session_started",
                       payload: %{"session_id" => ^session_id}
                     },
                     1_000

      # Simulate the channel process dying abnormally.
      send(pid, {:DOWN, make_ref(), :process, self(), :killed})

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "session_lost_lock",
                       payload: %{"session_id" => ^session_id}
                     },
                     1_000

      row = Repo.get!(PlanningSession, session_id)
      assert row.status == :lost_lock
      assert row.terminal_at != nil
    end

    test ":normal DOWN reason does NOT transition (clean exit leaves :active untouched)" do
      account = insert_account("PR3 lost_lock normal")
      user = insert_user_with_membership(account, "pr3-lost-lock-normal@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      pid =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      topic = "planning:#{account.id}"
      :ok = Phoenix.PubSub.subscribe(PubSub, topic)

      assert {:ok, %{session_id: session_id}} =
               PlanningSessionServer.start_session(
                 pid,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-01], ~D[2026-03-08]}
               )

      # Drain session_started.
      assert_receive %Phoenix.Socket.Broadcast{event: "session_started"}, 1_000

      send(pid, {:DOWN, make_ref(), :process, self(), :normal})
      # Give the handler a beat to run.
      _ = :sys.get_state(pid)

      # No lost_lock broadcast on clean exit.
      refute_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "session_lost_lock"
                     },
                     200

      row = Repo.get!(PlanningSession, session_id)
      assert row.status == :active
      assert row.terminal_at == nil
    end

    test ":shutdown DOWN reason does NOT transition (clean supervisor shutdown)" do
      account = insert_account("PR3 lost_lock shutdown")
      user = insert_user_with_membership(account, "pr3-lost-lock-shutdown@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      pid =
        start_session_server!(
          account_id: account.id,
          owner_user_id: user.id,
          owner_membership_id: membership_id,
          check_account_eligible_fn: fn _ -> true end
        )

      topic = "planning:#{account.id}"
      :ok = Phoenix.PubSub.subscribe(PubSub, topic)

      assert {:ok, %{session_id: session_id}} =
               PlanningSessionServer.start_session(
                 pid,
                 account.id,
                 user.id,
                 membership_id,
                 {~D[2026-03-01], ~D[2026-03-08]}
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "session_started"}, 1_000

      send(pid, {:DOWN, make_ref(), :process, self(), :shutdown})
      _ = :sys.get_state(pid)

      refute_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "session_lost_lock"
                     },
                     200

      row = Repo.get!(PlanningSession, session_id)
      assert row.status == :active
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  # Starts a `PlanningSessionServer` under the test supervisor. Each call
  # uses a fresh `id:` so multiple servers can coexist in the same test
  # (e.g. the overlap test starts two of them).
  defp start_session_server!(opts) do
    server_opts = [
      account_id: Keyword.fetch!(opts, :account_id),
      session_id: Keyword.get(opts, :session_id),
      owner_user_id: Keyword.get(opts, :owner_user_id),
      owner_membership_id: Keyword.get(opts, :owner_membership_id),
      check_account_eligible_fn: Keyword.get(opts, :check_account_eligible_fn, fn _ -> true end)
    ]

    start_supervised!({PlanningSessionServer, server_opts}, id: make_ref())
  end

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
