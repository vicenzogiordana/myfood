defmodule MealPlannerApi.Repo.Migrations.CreatePlanningSessionsMessagesExceptions do
  @moduledoc """
  PR1 of `ephemeral-planning-sessions` — creates the per-(account, range)
  range-lock surface as a first-class DB entity.

  Tables:

    * `planning_sessions`   — one row per session; carries the partial
      EXCLUDE constraint that refuses overlapping active ranges on the
      same account. Statuses: active, cancelled, expired, lost_lock,
      committed (terminal statuses retain the row for audit).
    * `planning_messages`   — chat rows scoped to a session; hard-deleted
      on terminal transitions (per design.md §"Confirm transition + hard-delete").
    * `planning_exceptions` — exception rows scoped to a session; same
      retention rule as messages.

  Postgres EXCLUDE requires the `btree_gist` extension to index the
  `account_id` (uuid) column with GiST; the extension is enabled
  unconditionally via `IF NOT EXISTS`.

  Naming + FK semantics mirror the existing planning migration
  (`20260322092000_create_planning_and_cooking_tables.exs`): binary_id
  PK, `references(:accounts, type: :binary_id, on_delete: :delete_all)`
  for tenancy scoping.
  """

  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist")

    create table(:planning_sessions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id,
        references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:range_from, :date, null: false)
      add(:range_to, :date, null: false)

      add(:status, :string, null: false, default: "active")

      add(:lock_owner_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:lock_owner_membership_id,
        references(:account_memberships, type: :binary_id, on_delete: :nilify_all)
      )

      add(:lease_expires_at, :utc_datetime_usec)
      add(:started_at, :utc_datetime_usec)
      add(:terminal_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    # Status whitelist — enforced at the DB level so a buggy caller cannot
    # write :unknown status values that bypass the schema's Ecto.Enum.
    create constraint(:planning_sessions, :planning_sessions_status_check,
             check:
               "status IN ('active', 'cancelled', 'expired', 'lost_lock', 'committed')"
           )

    # Partial EXCLUDE — refuses overlapping ACTIVE ranges on the same
    # account. Terminal statuses (cancelled / expired / lost_lock /
    # committed) are NOT covered, so a re-issued session in the same
    # range is allowed once the previous row transitions.
    # `daterange(..., '[]')` is the inclusive form (range_from and
    # range_to themselves overlap).
    execute("""
    ALTER TABLE planning_sessions
    ADD CONSTRAINT planning_sessions_no_overlap
    EXCLUDE USING gist (
      account_id WITH =,
      daterange(range_from, range_to, '[]') WITH &&
    ) WHERE (status = 'active')
    """)

    # Hot-query indexes for PR2+ (sweeper, fetch-active-for-range).
    create index(:planning_sessions, [:account_id, :status])
    create index(:planning_sessions, [:account_id, :lease_expires_at])

    create table(:planning_messages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id,
        references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:session_id,
        references(:planning_sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:role, :string, null: false)
      add(:content, :text, null: false)
      add(:intent_kind, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:planning_messages, :planning_messages_role_check,
             check: "role IN ('user', 'assistant', 'system')"
           )

    create index(:planning_messages, [:session_id])

    create table(:planning_exceptions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id,
        references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:session_id,
        references(:planning_sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string, null: false)
      add(:note, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:planning_exceptions, [:session_id])
  end
end
