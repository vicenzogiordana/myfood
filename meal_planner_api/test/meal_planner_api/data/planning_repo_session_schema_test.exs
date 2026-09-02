defmodule MealPlannerApi.Data.PlanningRepoSessionSchemaTest do
  @moduledoc """
  Migration + schema validation for `ephemeral-planning-sessions` PR1.

  These tests prove the migration landed the three tables, the
  `btree_gist` extension, and the partial EXCLUDE constraint on
  `planning_sessions`. The EXCLUDE constraint's WHERE clause is checked
  directly, and an end-to-end violation path (overlapping ranges on the
  same account raise `23P01` exclusion_violation) is exercised against
  the live DB so the assertion is real behavior, not just schema
  presence.

  The schema module files referenced (`PlanningSession`, `PlanningMessage`,
  `PlanningException`) are added in tasks 1.3-1.5 of the same PR; this
  test does NOT use them directly to keep PR1's surface independent of
  the changeset layer.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "btree_gist extension" do
    test "the extension is enabled on the live database" do
      [[extname]] =
        Repo.query!("SELECT extname FROM pg_extension WHERE extname = 'btree_gist'").rows

      assert extname == "btree_gist"
    end
  end

  describe "planning_sessions / planning_messages / planning_exceptions tables" do
    test "the three tables exist" do
      tables = list_tables(["planning_sessions", "planning_messages", "planning_exceptions"])

      assert "planning_sessions" in tables
      assert "planning_messages" in tables
      assert "planning_exceptions" in tables
    end

    test "planning_sessions exposes the expected columns" do
      columns = table_columns("planning_sessions")

      for col <- [
            "id",
            "account_id",
            "range_from",
            "range_to",
            "status",
            "lock_owner_user_id",
            "lock_owner_membership_id",
            "lease_expires_at",
            "started_at",
            "terminal_at",
            "inserted_at",
            "updated_at"
          ] do
        assert col in columns, "expected column #{col} in planning_sessions"
      end
    end

    test "planning_messages exposes the expected columns" do
      columns = table_columns("planning_messages")

      for col <- ["id", "account_id", "session_id", "role", "content", "intent_kind"] do
        assert col in columns, "expected column #{col} in planning_messages"
      end
    end

    test "planning_exceptions exposes the expected columns" do
      columns = table_columns("planning_exceptions")

      for col <- ["id", "account_id", "session_id", "kind", "note"] do
        assert col in columns, "expected column #{col} in planning_exceptions"
      end
    end
  end

  describe "planning_sessions_no_overlap EXCLUDE constraint" do
    test "the constraint exists as an EXCLUDE on planning_sessions" do
      [[conname, contype]] =
        Repo.query!(
          """
          SELECT conname, contype
          FROM pg_constraint
          WHERE conrelid = 'planning_sessions'::regclass
            AND conname = 'planning_sessions_no_overlap'
          """
        ).rows

      assert conname == "planning_sessions_no_overlap"
      assert contype == "x", "expected EXCLUDE constraint, got contype=#{contype}"
    end

    test "the constraint is partial: WHERE (status = 'active')" do
      [[condef]] =
        Repo.query!(
          """
          SELECT pg_get_constraintdef(oid)
          FROM pg_constraint
          WHERE conrelid = 'planning_sessions'::regclass
            AND conname = 'planning_sessions_no_overlap'
          """
        ).rows

      assert condef =~ ~r/EXCLUDE/i
      assert condef =~ ~r/btree_gist/i or condef =~ ~r/gist/i
      assert condef =~ ~r/account_id.*=/i
      assert condef =~ ~r/daterange/i
      assert condef =~ ~r/range_from.*range_to/i or condef =~ ~r/range_from.*range_to/i
      assert condef =~ ~r/status/i
      assert condef =~ ~r/'active'/i
    end
  end

  describe "EXCLUDE constraint behavior end-to-end" do
    test "two non-overlapping active ranges on the same account coexist" do
      account_id = insert_account!()

      assert %Postgrex.Result{num_rows: 1} =
               insert_active_session!(account_id, ~D[2026-03-01], ~D[2026-03-08])

      assert %Postgrex.Result{num_rows: 1} =
               insert_active_session!(account_id, ~D[2026-03-15], ~D[2026-03-22])
    end

    test "two overlapping active ranges on the same account raise 23P01 (exclusion_violation)" do
      account_id = insert_account!()

      assert %Postgrex.Result{num_rows: 1} =
               insert_active_session!(account_id, ~D[2026-03-01], ~D[2026-03-08])

      assert_raises_postgres("23P01", fn ->
        insert_active_session!(account_id, ~D[2026-03-05], ~D[2026-03-12])
      end)
    end

    test "a cancelled session does NOT block a new active session in the same range" do
      account_id = insert_account!()

      assert %Postgrex.Result{num_rows: 1} =
               insert_active_session!(account_id, ~D[2026-03-01], ~D[2026-03-08])

      # Move the first row to :cancelled; the partial EXCLUDE must release the lock.
      Repo.query!(
        """
        UPDATE planning_sessions
        SET status = 'cancelled', terminal_at = now(), updated_at = now()
        WHERE account_id = $1
        """,
        [Ecto.UUID.dump!(account_id)]
      )

      assert %Postgrex.Result{num_rows: 1} =
               insert_active_session!(account_id, ~D[2026-03-01], ~D[2026-03-08])
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp list_tables(expected_names) do
    query = """
    SELECT tablename
    FROM pg_catalog.pg_tables
    WHERE schemaname = 'public'
      AND tablename = ANY($1::text[])
    """

    rows = Repo.query!(query, [expected_names]).rows
    Enum.map(rows, fn [name] -> name end)
  end

  defp table_columns(table) do
    query = """
    SELECT column_name
    FROM information_schema.columns
    WHERE table_name = $1
    ORDER BY ordinal_position
    """

    rows = Repo.query!(query, [table]).rows
    Enum.map(rows, fn [name] -> name end)
  end

  defp assert_raises_postgres(expected_sqlstate, fun) do
    try do
      result = fun.()

      flunk(
        "expected PostgreSQL exception #{expected_sqlstate}, got #{inspect(result)}"
      )
    rescue
      ex in Postgrex.Error ->
        assert ex.postgres.pg_code == expected_sqlstate,
               "expected sqlstate #{expected_sqlstate}, got pg_code=#{ex.postgres.pg_code}"
    end
  end

  defp insert_account! do
    plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")
    {:ok, account_id} = Ecto.UUID.dump(Ecto.UUID.generate())
    {:ok, plan_id} = Ecto.UUID.dump(plan.id)
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO accounts (id, name, plan, default_budget_cents, subscription_plan_id, inserted_at, updated_at)
      VALUES ($1, 'PR1 Schema Test', 'family_4', 0, $2, $3, $3)
      """,
      [account_id, plan_id, now]
    )

    Ecto.UUID.cast!(account_id)
  end

  defp insert_active_session!(account_id, range_from, range_to) do
    {:ok, session_id} = Ecto.UUID.dump(Ecto.UUID.generate())
    {:ok, account_id_bin} = Ecto.UUID.dump(account_id)
    now = DateTime.utc_now()
    lease_expires = DateTime.add(now, 120, :second)

    Repo.query!(
      """
      INSERT INTO planning_sessions (
        id, account_id, range_from, range_to, status,
        lock_owner_user_id, lock_owner_membership_id,
        lease_expires_at, started_at, terminal_at,
        inserted_at, updated_at
      )
      VALUES (
        $1, $2, $3, $4, 'active',
        NULL, NULL,
        $5, $6, NULL,
        $6, $6
      )
      RETURNING id
      """,
      [
        session_id,
        account_id_bin,
        range_from,
        range_to,
        lease_expires,
        now
      ]
    )
  end
end
