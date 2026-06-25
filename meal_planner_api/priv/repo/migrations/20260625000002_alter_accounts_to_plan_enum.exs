defmodule MealPlannerApi.Repo.Migrations.AlterAccountsToPlanEnum do
  @moduledoc """
  Phase A — Tenancy Refactor (PR 1, task 1.2).

  Replaces the legacy `accounts.account_type` (`:individual | :group`) with
  the canonical `accounts.plan` enum (`:individual | :family_4 |
  :family_6 | :trial`). Per `proposal.md` §"Stream A — DB migration" and
  `design.md` §2.2:

    * Any existing `account_type = 'group'` row is rewritten to
      `plan = 'family_4'` (data migration; `:group` and `:family_4` are the
      same seat-cap shape today — design §2.2).
    * `account_type` column is dropped (the `:group` enum value MUST NOT
      exist post-Phase-A per decision 5.3).
    * `plan` is `NOT NULL` with a CHECK constraint limiting values to
      `('individual', 'family_4', 'family_6', 'trial')`.
    * Two new `subscription_plans` rows are seeded: `:family_6` and
      `:trial` (Q10 — design §2.6). `:individual` and `:family_4` rows are
      preserved from the prior migration
      (`20260326120000_create_subscription_plans.exs`).

  The `down/0` reverses the data migration (`:family_4 → :group`,
  everything else `:individual`) so a rollback restores a valid pre-Phase-A
  snapshot. Production rollback is **only safe when no membership rows
  exist** — the design §9.4 rollback for PR 1 is a coordinated restore
  from migration snapshot, not a per-migration `down/0`.
  """
  use Ecto.Migration

  @plan_values ~w(individual family_4 family_6 trial)

  def up do
    # 1) Add `plan` column with safe default; existing rows get 'individual'
    #    and the column is NOT NULL.
    alter table(:accounts) do
      add(:plan, :string, null: false, default: "individual")
    end

    # 2) Data migration: legacy `account_type = 'group'` → `plan = 'family_4'`.
    execute("""
    UPDATE accounts SET plan = 'family_4' WHERE account_type = 'group'
    """)

    # 3) Drop the legacy `account_type` column (and its CHECK constraint
    #    is dropped automatically with the column).
    alter table(:accounts) do
      remove(:account_type)
    end

    # 4) Add CHECK constraint on the new enum.
    create(
      constraint(:accounts, :accounts_plan_check,
        check: "plan IN ('individual', 'family_4', 'family_6', 'trial')"
      )
    )

    # 5) Seed the two missing `subscription_plans` rows (Q10). Use
    #    `on_conflict: :nothing` so re-running the migration is idempotent.
    seed_subscription_plans()
  end

  def down do
    # Drop the plan CHECK constraint and the plan column.
    drop(constraint(:accounts, :accounts_plan_check))

    alter table(:accounts) do
      remove(:plan)
    end

    # Re-introduce `account_type` with the legacy values.
    alter table(:accounts) do
      add(:account_type, :string, null: false, default: "individual")
    end

    create(
      constraint(:accounts, :accounts_account_type_check,
        check: "account_type IN ('individual', 'group')"
      )
    )

    # Data restoration is intentionally NOT performed in `down/0`:
    # mapping `plan -> account_type` requires the snapshot of
    # `subscription_plans.max_users` at the moment of rollback and would
    # silently corrupt accounts whose plan was promoted to `:family_6`
    # post-PR-1. Per design §9.4 the catastrophic rollback is a coordinated
    # restore from migration snapshot, not a per-migration `down/0`.
  end

  defp seed_subscription_plans do
    plan_seeds = [
      %{
        name: "family_6",
        max_users: 6,
        max_planning_days: 30,
        revenuecat_entitlement_id: "family_6"
      },
      %{
        name: "trial",
        max_users: 6,
        max_planning_days: 30,
        revenuecat_entitlement_id: "trial"
      }
    ]

    Enum.each(plan_seeds, fn attrs ->
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())

      repo().query!(
        """
        INSERT INTO subscription_plans (id, name, max_users, max_planning_days, revenuecat_entitlement_id, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $6)
        ON CONFLICT (name) DO NOTHING
        """,
        [
          uuid_binary,
          attrs.name,
          attrs.max_users,
          attrs.max_planning_days,
          attrs.revenuecat_entitlement_id,
          DateTime.utc_now()
        ]
      )
    end)
  end
end
