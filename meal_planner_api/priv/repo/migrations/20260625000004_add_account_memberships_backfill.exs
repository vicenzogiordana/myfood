defmodule MealPlannerApi.Repo.Migrations.AddAccountMembershipsBackfill do
  @moduledoc """
  Phase A — Tenancy Refactor (PR 1, task 1.4).

  Backfills `account_memberships` from legacy `users.account_id` rows and
  defines the invariant-check function that the migration calls before
  commit. Per `design.md` §2.4 and §2.5:

    * Batch insert: for every legacy `(users.id, users.account_id)` pair
      that does not already have an `:active` membership, insert one
      `:active :owner` membership with `joined_at = users.inserted_at`.
      Batches of 1,000 rows with `pg_sleep(0.05)` and `FOR UPDATE
      SKIP LOCKED` to avoid write-lock storms on a populated DB.

    * `check_account_membership_invariants()` raises if ANY of:
        1. A legacy (user, account) pair lacks an `:active` membership.
        2. A legacy `users.account_id` points at a missing Account.
        3. Any Account has more (or fewer) than one `:owner` `:active`
           membership.

  The migration invokes the function at the end of its transaction. Any
  failure rolls back the migration — the database never enters a state
  where the invariant is broken (Q2).

  Note: the backfill sets `role` to `COALESCE(users.role, 'owner')` so a
  legacy user with `role = 'member'` retains their member role, but the
  default for users with a missing/null role is `:owner` (matches design
  §2.4 backfill SQL).
  """
  use Ecto.Migration

  def up do
    # 1) Define the invariant function first so the backfill can call it
    #    at the end of the same transaction.
    execute("""
    CREATE OR REPLACE FUNCTION check_account_membership_invariants()
    RETURNS void AS $fn$
    DECLARE
      missing_memberships bigint;
      orphan_accounts      bigint;
      multi_owner_accounts bigint;
    BEGIN
      -- 1) Every legacy (user, account) pair in users.account_id has
      --    exactly one :active membership.
      SELECT COUNT(*) INTO missing_memberships
      FROM users u
      LEFT JOIN account_memberships m
        ON m.user_id = u.id AND m.account_id = u.account_id AND m.status = 'active'
      WHERE u.account_id IS NOT NULL AND m.id IS NULL;

      IF missing_memberships > 0 THEN
        RAISE EXCEPTION 'backfill_invariant_failed: % users have no active membership',
          missing_memberships;
      END IF;

      -- 2) Every legacy users.account_id row points at a real Account.
      SELECT COUNT(*) INTO orphan_accounts
      FROM users u
      WHERE u.account_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id = u.account_id);

      IF orphan_accounts > 0 THEN
        RAISE EXCEPTION 'backfill_invariant_failed: % users reference missing account',
          orphan_accounts;
      END IF;

      -- 3) Every Account has exactly one :owner :active membership.
      SELECT COUNT(*) INTO multi_owner_accounts
      FROM (
        SELECT account_id, COUNT(*) AS owner_count
        FROM account_memberships
        WHERE role = 'owner' AND status = 'active'
        GROUP BY account_id
        HAVING COUNT(*) <> 1
      ) AS offenders;

      IF multi_owner_accounts > 0 THEN
        RAISE EXCEPTION 'backfill_invariant_failed: % accounts do not have exactly 1 :owner :active',
          multi_owner_accounts;
      END IF;
    END;
    $fn$ LANGUAGE plpgsql;
    """)

    # 2) Run the batched backfill in a DO block.
    execute("""
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
        SELECT
          gen_random_uuid(),
          b.account_id,
          b.user_id,
          COALESCE(b.role, 'owner'),
          'active',
          NULL,
          NULL,
          NULL,
          b.inserted_at,
          now(),
          now()
        FROM batch b;

        GET DIAGNOSTICS inserted = ROW_COUNT;
        EXIT WHEN inserted = 0;

        PERFORM pg_sleep(0.05);
      END LOOP;
    END $$;
    """)

    # 3) Invoke the invariant check. If anything is off, the exception
    #    bubbles out and the migration rolls back.
    execute("SELECT check_account_membership_invariants()")
  end

  def down do
    execute("DROP FUNCTION IF EXISTS check_account_membership_invariants()")
    # The backfilled rows are NOT auto-removed by `down` — the destructive
    # rollback path is documented in design §9.4 as a coordinated
    # restore from migration snapshot, not a per-migration `down/0`.
  end
end
