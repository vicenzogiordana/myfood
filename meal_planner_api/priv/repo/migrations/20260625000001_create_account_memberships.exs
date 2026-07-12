defmodule MealPlannerApi.Repo.Migrations.CreateAccountMemberships do
  @moduledoc """
  Phase A — Tenancy Refactor (PR 1, task 1.1).

  Creates the `account_memberships` join table. Per
  `proposal.md` §"Stream A — DB migration" and `design.md` §2.1:

    * `id :binary_id` (UUID) primary key
    * `account_id` and `user_id` FKs with `on_delete: :delete_all`
    * `role` and `status` as `:string` with CHECK constraints
    * `invited_by_user_id` FK with `on_delete: :nilify_all` (audit
      trail survives User deletion — full user deletion is B1, out of
      scope for Phase A)
    * `invite_token_hash` (SHA-256 of the plaintext) — nil after accept
    * `invite_expires_at` — nil after accept; defaulted to 7 days
    * `joined_at` — set on `:invited → :active`
    * Three lookup indexes: `(user_id, account_id)`, `(account_id, status)`,
      `(user_id, status)` — names follow the existing project convention
    * One partial unique index on `(account_id, user_id) WHERE status = 'active'`
      — the canonical "exactly one active membership per (account, user)"
  """
  use Ecto.Migration

  def change do
    create table(:account_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :status, :string, null: false
      add :invited_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :invite_token_hash, :string
      add :invite_expires_at, :utc_datetime_usec
      add :joined_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:account_memberships, :account_memberships_role_check,
             check: "role IN ('owner', 'member')"
           )

    create constraint(:account_memberships, :account_memberships_status_check,
             check: "status IN ('active', 'invited', 'suspended')"
           )

    create index(:account_memberships, [:user_id, :account_id],
           name: :account_memberships_user_id_account_id_index)

    create index(:account_memberships, [:account_id, :status],
           name: :account_memberships_account_id_status_index)

    create index(:account_memberships, [:user_id, :status],
           name: :account_memberships_user_id_status_index)

    create unique_index(:account_memberships, [:account_id, :user_id],
           where: "status = 'active'",
           name: :account_memberships_active_account_user_unique_index
         )
  end
end
