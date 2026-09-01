defmodule MealPlannerApi.Repo.Migrations.CreateEmailCodeAuthTables do
  @moduledoc """
  Phase 1 — Persistence and Code Request (issue #31).

  Adds four tables for email-code authentication and account-selection
  continuations, per `design.md` §"Persistence Shapes":

    * `email_verification_codes` — UUID id, user_id FK, normalized
      email, SHA-256 code_hash, expiry, nullable consumed_at, plus
      pending/hash lookup indexes.
    * `email_auth_events` — constrained `request|verification_failure`,
      normalized email, nullable inet client IP, occurrence time, and
      rolling-window indexes used to derive `Retry-After`.
    * `account_selection_continuations` — UUID id, unique SHA-256
      token_hash, user_id FK, expiry, nullable consumed_at.
    * `account_selection_continuation_memberships` — continuation and
      membership FKs with composite primary key, used by Phase 3 to
      bind a continuation to its allowed membership set.

  All four tables are created in a single additive migration so that
  rollback can drop them together, and so that the additive rollout
  step ("apply additive tables before routes" — design §"Migration /
  Rollout") is a single migration.
  """
  use Ecto.Migration

  def change do
    create table(:email_verification_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :code_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:email_verification_codes, [:user_id, :email],
           name: :email_verification_codes_user_id_email_index)

    create index(:email_verification_codes, [:code_hash],
           name: :email_verification_codes_code_hash_index)

    create index(:email_verification_codes, [:consumed_at, :expires_at],
           name: :email_verification_codes_consumed_at_expires_at_index)

    create table(:email_auth_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :email, :string, null: false
      add :client_ip, :string
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:email_auth_events, :email_auth_events_kind_check,
             check: "kind IN ('request', 'verification_failure')"
           )

    create index(:email_auth_events, [:email, :occurred_at],
           name: :email_auth_events_email_occurred_at_index)

    create index(:email_auth_events, [:client_ip, :occurred_at],
           name: :email_auth_events_client_ip_occurred_at_index)

    create table(:account_selection_continuations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:account_selection_continuations, [:token_hash],
             name: :account_selection_continuations_token_hash_unique_index
           )

    create table(:account_selection_continuation_memberships,
           primary_key: false) do
      add :continuation_id,
          references(:account_selection_continuations,
            type: :binary_id,
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false

      add :membership_id,
          references(:account_memberships, type: :binary_id, on_delete: :delete_all),
          primary_key: true,
          null: false
    end

    create index(:account_selection_continuation_memberships, [:membership_id],
           name: :account_selection_continuation_memberships_membership_id_index)
  end
end
