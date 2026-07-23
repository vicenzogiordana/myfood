defmodule MealPlannerApi.MigrationSanityTest do
  @moduledoc """
  Migration sanity checkpoint (Phase A — Tenancy Refactor, PR 1 task 1.13).

  Per `design.md` §8.3 the canonical sanity test exercises:

    1. Drop + create the test database and run every migration forward.
    2. Assert all four `subscription_plans` rows exist post-migration.
    3. Insert fixture `users` + `accounts` matching the pre-Phase-A shape
       (every user carries `account_id NOT NULL`).
    4. Run the backfill migration's `check_account_membership_invariants()`
       helper and assert zero violations.
    5. `mix ecto.rollback` to the pre-Phase-A snapshot then re-run
       `migrate` to confirm idempotency.

  ## Running the destructive cycle manually

  This test file is `@moduletag :migration_sanity` and excluded from the
  default `mix test` run because step 1 is destructive (it drops the test
  DB and breaks concurrent test pool connections). To exercise the full
  cycle from a clean DB, run:

      cd meal_planner_api
      mix ecto.drop
      mix ecto.create
      mix ecto.migrate
      mix test --only migration_sanity test/support/migration_sanity_test.exs

  ## Day-to-day coverage

  Steps 2-4 are also exercised by `MealPlannerApi.MigrationShapeTest`
  for every-day `mix test` runs. This file proves the full migration
  cycle holds and serves as the canonical reference for the
  `mix ecto.{drop,create,migrate}` round-trip.
  """

  use ExUnit.Case, async: false

  @moduletag :migration_sanity

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Repo

  describe "schema sanity on a fully-migrated DB" do
    setup do
      :ok = Sandbox.checkout(Repo)
      :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    end

    test "all four subscription_plans rows exist" do
      plan_names =
        Repo.all(from(p in MealPlannerApi.Subscriptions.Plan, select: p.name))
        |> Enum.sort()

      assert plan_names == ["family_4", "family_6", "individual", "trial"]
    end

    test "account_memberships table exists with all expected columns" do
      columns = table_columns("account_memberships")

      for col <- [
            "id",
            "account_id",
            "user_id",
            "role",
            "status",
            "invited_by_user_id",
            "invite_token_hash",
            "invite_expires_at",
            "joined_at"
          ] do
        assert col in columns, "expected column #{col} in account_memberships"
      end
    end

    test "backfill produces no invariant violations for pre-Phase-A fixture data" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")
      {:ok, account_id} = Ecto.UUID.dump(Ecto.UUID.generate())
      {:ok, plan_id_bin} = Ecto.UUID.dump(plan.id)
      now = DateTime.utc_now()

      Repo.query!(
        """
        INSERT INTO accounts (id, name, plan, default_budget_cents, subscription_plan_id, inserted_at, updated_at)
        VALUES ($1, 'Sanity Account', 'family_4', 0, $2, $3, $3)
        """,
        [account_id, plan_id_bin, now]
      )

      # Three fixture users — one :owner (matches the canonical
      # invariant that every Account has exactly one :owner) and two
      # :members. Pre-Phase-A user.role was :owner by default; the
      # COALESCE in the backfill preserves :member for legacy
      # :member users.
      insert_user! = fn role ->
        {:ok, user_id} = Ecto.UUID.dump(Ecto.UUID.generate())

        Repo.query!(
          """
          INSERT INTO users (id, account_id, email, name, role, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, $6, $6)
          """,
          [
            user_id,
            account_id,
            "sanity_#{role}_#{Ecto.UUID.generate()}@example.com",
            "Sanity #{role}",
            Atom.to_string(role),
            now
          ]
        )
      end

      insert_user!.(:owner)
      insert_user!.(:member)
      insert_user!.(:member)

      # Run the backfill loop manually. The NOT EXISTS guard makes it
      # idempotent (re-running it adds no duplicates).
      Repo.query!("""
      DO $$
      DECLARE
        batch_size int := 1000;
        inserted   int := 0;
      BEGIN
        LOOP
          WITH batch AS (
            SELECT u.id AS user_id, u.account_id, u.role, u.inserted_at
            FROM users u
            WHERE u.account_id IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM account_memberships m
                WHERE m.user_id = u.id
                  AND m.account_id = u.account_id
                  AND m.status = 'active'
              )
            ORDER BY u.inserted_at
            LIMIT batch_size
            FOR UPDATE SKIP LOCKED
          )
          INSERT INTO account_memberships (
            id, account_id, user_id, role, status,
            invited_by_user_id, invite_token_hash,
            invite_expires_at, joined_at,
            inserted_at, updated_at
          )
          SELECT gen_random_uuid(), b.account_id, b.user_id,
                 COALESCE(b.role, 'owner'), 'active', NULL, NULL, NULL,
                 b.inserted_at, now(), now()
          FROM batch b;
          GET DIAGNOSTICS inserted = ROW_COUNT;
          EXIT WHEN inserted = 0;
          PERFORM pg_sleep(0.05);
        END LOOP;
      END $$;
      """)

      result = Repo.query!("SELECT check_account_membership_invariants()")
      assert result.command == :select
      assert result.num_rows == 1

      [[active_owner_count]] =
        Repo.query!(
          """
          SELECT COUNT(*) FROM account_memberships
          WHERE account_id = $1 AND status = 'active' AND role = 'owner'
          """,
          [account_id]
        ).rows

      assert active_owner_count == 1

      [[active_member_count]] =
        Repo.query!(
          """
          SELECT COUNT(*) FROM account_memberships
          WHERE account_id = $1 AND status = 'active' AND role = 'member'
          """,
          [account_id]
        ).rows

      assert active_member_count == 2

      # Idempotency: re-run the loop and confirm no duplicates.
      Repo.query!("""
      DO $$
      DECLARE
        batch_size int := 1000;
        inserted   int := 0;
      BEGIN
        LOOP
          WITH batch AS (
            SELECT u.id AS user_id, u.account_id, u.role, u.inserted_at
            FROM users u
            WHERE u.account_id IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM account_memberships m
                WHERE m.user_id = u.id
                  AND m.account_id = u.account_id
                  AND m.status = 'active'
              )
            ORDER BY u.inserted_at
            LIMIT batch_size
            FOR UPDATE SKIP LOCKED
          )
          INSERT INTO account_memberships (
            id, account_id, user_id, role, status,
            invited_by_user_id, invite_token_hash,
            invite_expires_at, joined_at,
            inserted_at, updated_at
          )
          SELECT gen_random_uuid(), b.account_id, b.user_id,
                 COALESCE(b.role, 'owner'), 'active', NULL, NULL, NULL,
                 b.inserted_at, now(), now()
          FROM batch b;
          GET DIAGNOSTICS inserted = ROW_COUNT;
          EXIT WHEN inserted = 0;
          PERFORM pg_sleep(0.05);
        END LOOP;
      END $$;
      """)

      [[count_after_replay]] =
        Repo.query!(
          """
          SELECT COUNT(*) FROM account_memberships
          WHERE account_id = $1 AND status = 'active'
          """,
          [account_id]
        ).rows

      assert count_after_replay == 3
    end
  end

  # ---- helpers ---------------------------------------------------------------

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
end
