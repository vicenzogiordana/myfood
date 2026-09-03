defmodule MealPlannerApi.Generation.PlanningSession.SweeperTest do
  @moduledoc """
  Tests for `MealPlannerApi.Generation.PlanningSession.Sweeper` —
  PR3 (`ephemeral-planning-sessions`, Phase 3, tasks 3.5–3.6).

  Spec coverage:

    * `@task 3.5` — An `:active` session with `lease_expires_at` in
      the past transitions to `:expired` on the next sweeper tick AND
      broadcasts `session_expired` on `planning:<account_id>`.
    * `@task 3.5` triangulation — Terminal sessions are SKIPPED even
      when their `lease_expires_at` is in the past (no double transition,
      no spurious broadcast).

  The tick interval is overridden via the `:interval` opt to 100ms so
  the test does not have to wait the production 30s.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Generation.PlanningSession.Sweeper
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Planning.PlanningMessage
  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.PubSub
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(MealPlannerApi.Repo)
    Sandbox.mode(MealPlannerApi.Repo, {:shared, self()})
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    :ok
  end

  # ---------------------------------------------------------------------------
  # @task 3.5 — happy path: past lease transitions to :expired
  # ---------------------------------------------------------------------------

  describe "tick — past lease transitions to :expired (@task 3.5)" do
    test "an :active session with lease_expires_at 1s in the past transitions to :expired and broadcasts session_expired" do
      account = insert_account("PR3 sweeper happy")
      user = insert_user_with_membership(account, "pr3-sweeper-happy@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      # Past lease so the sweeper picks it up on the first tick.
      past_lease = DateTime.add(DateTime.utc_now(), -1, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-03-01],
          range_to: ~D[2026-03-08],
          lock_owner_user_id: user.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: past_lease
        })

      # Seed a child row so we can prove the hard-delete contract.
      Repo.insert!(%PlanningMessage{
        account_id: account.id,
        session_id: session.id,
        role: :user,
        content: "hi"
      })

      topic = "planning:#{account.id}"
      :ok = Phoenix.PubSub.subscribe(PubSub, topic)

      # Start the sweeper with a 100ms tick — the production default is
      # 30_000ms but we override for test latency.
      start_supervised!({Sweeper, interval: 100, name: :test_planning_sweeper},
        id: :test_planning_sweeper
      )

      session_id = session.id

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "session_expired",
                       payload: %{"session_id" => ^session_id}
                     },
                     2_000

      row = Repo.get!(PlanningSession, session_id)
      assert row.status == :expired
      assert row.terminal_at != nil

      # Children hard-deleted.
      children_count =
        Repo.one!(
          from(m in PlanningMessage,
            where: m.session_id == ^session_id,
            select: count(m.id)
          )
        )

      assert children_count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # @task 3.5 triangulation — terminal sessions are skipped
  # ---------------------------------------------------------------------------

  describe "tick — terminal sessions are skipped (no double transition)" do
    test "an already-cancelled session with past lease_expires_at is NOT re-expired by the sweeper" do
      account = insert_account("PR3 sweeper skip terminal")
      user = insert_user_with_membership(account, "pr3-sweeper-skip@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      future_lease = DateTime.add(DateTime.utc_now(), 600, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-04-01],
          range_to: ~D[2026-04-08],
          lock_owner_user_id: user.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: future_lease
        })

      # Cancel first so the row reaches a terminal status.
      assert {:ok, _} = PlanningRepo.cancel_session(account.id, session.id, membership_id, false)

      # Now force the lease into the past (simulates a clock progression
      # after the user already cancelled — the sweeper must NOT re-fire).
      Repo.update_all(
        from(s in PlanningSession, where: s.id == ^session.id),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      topic = "planning:#{account.id}"
      :ok = Phoenix.PubSub.subscribe(PubSub, topic)

      start_supervised!({Sweeper, interval: 100, name: :test_planning_sweeper_skip},
        id: :test_planning_sweeper_skip
      )

      # Wait for at least one tick to confirm the sweeper ran.
      Process.sleep(250)

      # The terminal status must NOT flip from :cancelled to :expired.
      row = Repo.get!(PlanningSession, session.id)
      assert row.status == :cancelled

      # No `session_expired` broadcast emitted.
      refute_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "session_expired"
                     },
                     200
    end

    test "an :active session with FUTURE lease_expires_at is NOT expired by the sweeper" do
      account = insert_account("PR3 sweeper future lease")
      user = insert_user_with_membership(account, "pr3-sweeper-future@example.com", :owner)
      membership_id = owner_membership_id(account.id, user.id)

      future_lease = DateTime.add(DateTime.utc_now(), 600, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-05-01],
          range_to: ~D[2026-05-08],
          lock_owner_user_id: user.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: future_lease
        })

      topic = "planning:#{account.id}"
      :ok = Phoenix.PubSub.subscribe(PubSub, topic)

      start_supervised!({Sweeper, interval: 100, name: :test_planning_sweeper_future},
        id: :test_planning_sweeper_future
      )

      Process.sleep(250)

      row = Repo.get!(PlanningSession, session.id)
      assert row.status == :active

      refute_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "session_expired"
                     },
                     200
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
