defmodule MealPlannerApi.Repo.Migrations.CreateRevenuecatTables do
  use Ecto.Migration

  def change do
    create table(:revenuecat_customers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :rc_app_user_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:revenuecat_customers, [:account_id])
    create index(:revenuecat_customers, [:user_id])
    create unique_index(:revenuecat_customers, [:rc_app_user_id])

    create table(:revenuecat_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :rc_app_user_id, :string, null: false
      add :entitlement_id, :string, null: false
      add :product_identifier, :string
      add :is_active, :boolean, null: false
      add :will_renew, :boolean
      add :store, :string
      add :purchase_date, :utc_datetime_usec
      add :expiration_date, :utc_datetime_usec
      add :grace_period_expires_date, :utc_datetime_usec
      add :raw_payload, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:revenuecat_entitlements, [:account_id])
    create index(:revenuecat_entitlements, [:rc_app_user_id])
    create index(:revenuecat_entitlements, [:entitlement_id])
    create unique_index(:revenuecat_entitlements, [:account_id, :entitlement_id])

    create table(:revenuecat_webhook_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, :string, null: false
      add :event_type, :string, null: false
      add :rc_app_user_id, :string, null: false
      add :account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :status, :string, null: false, default: "received"
      add :received_at, :utc_datetime_usec, null: false
      add :processed_at, :utc_datetime_usec
      add :error_message, :text
      add :payload, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:revenuecat_webhook_events, [:event_id])
    create index(:revenuecat_webhook_events, [:account_id])
    create index(:revenuecat_webhook_events, [:rc_app_user_id])
    create index(:revenuecat_webhook_events, [:status])
    create index(:revenuecat_webhook_events, [:received_at])

    create constraint(:revenuecat_webhook_events, :revenuecat_webhook_events_status_check,
             check: "status IN ('received', 'processed', 'failed', 'ignored')"
           )

    create table(:revenuecat_subscription_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :rc_app_user_id, :string, null: false
      add :product_identifier, :string, null: false
      add :entitlement_id, :string
      add :status, :string, null: false
      add :period_type, :string
      add :purchase_date, :utc_datetime_usec
      add :expiration_date, :utc_datetime_usec
      add :store, :string
      add :event_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:revenuecat_subscription_snapshots, [:account_id])
    create index(:revenuecat_subscription_snapshots, [:rc_app_user_id])
    create index(:revenuecat_subscription_snapshots, [:event_id])
    create index(:revenuecat_subscription_snapshots, [:inserted_at])
  end
end
