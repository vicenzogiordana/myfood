defmodule MealPlannerApi.Repo.Migrations.CreateAccountsAndUsers do
  use Ecto.Migration

  def change do
    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :account_type, :string, null: false
      add :default_budget_cents, :integer, null: false, default: 0
      # FK to supermarkets is added in Context 4 to keep migration order stable.
      add :preferred_supermarket_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:accounts, :accounts_account_type_check,
             check: "account_type IN ('individual', 'group')"
           )

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :email, :string, null: false
      add :name, :string, null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:users, [:account_id])
    create unique_index(:users, [:email])

    create constraint(:users, :users_role_check,
             check: "role IN ('owner', 'member')"
           )
  end
end
