defmodule MealPlannerApi.Repo.Migrations.MakeUserAccountIdNullable do
  @moduledoc """
  Phase A — Tenancy Refactor (PR 1, task 1.3).

  Relaxes `users.account_id` to NULL for the dual-write window so that
  `access_v2` JWT holders can have `current_user.account_id == nil` while
  the `current_membership.account_id` carries the real tenancy (decision
  5.1 — design §2.3).

  The down migration restores `NOT NULL` AFTER a backfill-from-membership
  SQL step (the destructive path is documented in design §9.4 — rollback
  is a coordinated restore, not a per-migration `down/0`).

  Because the FK is preserved and the column is now nullable, application
  code that still writes `account_id` (pre-Phase-A registration path) keeps
  working; new `access_v2` Users can have a nil `account_id`.
  """
  use Ecto.Migration

  def up do
    # ALTER COLUMN ... DROP NOT NULL preserves the existing FK constraint
    # and avoids creating a duplicate constraint (which Ecto's
    # `modify :references` would attempt).
    execute("ALTER TABLE users ALTER COLUMN account_id DROP NOT NULL")
  end

  def down do
    # Restoring NOT NULL after a dual-write window would block if any
    # user.account_id rows were nulled in the meantime. In practice the
    # catastrophic rollback described in design §9.4 restores from a
    # migration snapshot rather than running this in isolation.
    execute("ALTER TABLE users ALTER COLUMN account_id SET NOT NULL")
  end
end
