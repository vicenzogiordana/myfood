defmodule MealPlannerApi.Repo.Migrations.CreateInventoryAndShoppingTables do
  use Ecto.Migration

  def change do
    create table(:supermarkets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :chain, :string
      add :pricing_scrape_enabled, :boolean, null: false, default: true
      add :pricing_scrape_url, :text
      add :active_from, :utc_datetime_usec
      add :active_until, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:supermarkets, [:name])

    create table(:supermarket_catalogs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :supermarket_id,
          references(:supermarkets, type: :binary_id, on_delete: :delete_all),
          null: false

      add :ingredient_id,
          references(:ingredients, type: :binary_id, on_delete: :restrict),
          null: false

      add :price_cents_ars, :integer, null: false
      add :unit, :string, null: false
      add :price_date, :date, null: false
      add :last_scraped_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:supermarket_catalogs, [:supermarket_id])
    create index(:supermarket_catalogs, [:ingredient_id])
    create index(:supermarket_catalogs, [:price_date])
    create unique_index(:supermarket_catalogs, [:supermarket_id, :ingredient_id, :price_date])

    create constraint(:supermarket_catalogs, :supermarket_catalogs_price_non_negative,
             check: "price_cents_ars >= 0"
           )

    create table(:checkout_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :status, :string, null: false, default: "draft"
      add :checkout_type, :string, null: false
      add :grouping_by_supermarket, :map
      add :total_cents, :integer

      add :confirmed_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :confirmed_at, :utc_datetime_usec
      add :invalidated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:checkout_sessions, [:account_id])
    create index(:checkout_sessions, [:status])
    create index(:checkout_sessions, [:inserted_at])

    create constraint(:checkout_sessions, :checkout_sessions_status_check,
             check: "status IN ('draft', 'processing', 'completed', 'abandoned')"
           )

    create constraint(:checkout_sessions, :checkout_sessions_type_check,
             check: "checkout_type IN ('physical', 'online')"
           )

    create table(:shopping_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :scheduled_meal_id,
          references(:scheduled_meals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :planned_date, :date, null: false

      add :ingredient_id,
          references(:ingredients, type: :binary_id, on_delete: :restrict),
          null: false

      add :quantity_milli, :integer, null: false
      add :unit, :string, null: false

      add :assigned_supermarket_id,
          references(:supermarkets, type: :binary_id, on_delete: :nilify_all)

      add :status, :string, null: false, default: "pending"
      add :estimated_price_cents, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:shopping_items, [:account_id])
    create index(:shopping_items, [:scheduled_meal_id])
    create index(:shopping_items, [:planned_date])
    create index(:shopping_items, [:ingredient_id])
    create index(:shopping_items, [:status])

    create constraint(:shopping_items, :shopping_items_status_check,
             check: "status IN ('pending', 'in_cart', 'checked_out', 'archived')"
           )

    create constraint(:shopping_items, :shopping_items_unit_check,
             check: "unit IN ('g', 'ml', 'unit')"
           )

    create constraint(:shopping_items, :shopping_items_quantity_positive,
             check: "quantity_milli > 0"
           )

    create constraint(:shopping_items, :shopping_items_estimated_price_non_negative,
             check: "estimated_price_cents IS NULL OR estimated_price_cents >= 0"
           )

    create table(:inventory_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :ingredient_id,
          references(:ingredients, type: :binary_id, on_delete: :restrict),
          null: false

      add :quantity_milli, :integer, null: false
      add :unit, :string, null: false
      add :source_kind, :string, null: false
      add :acquired_price_cents, :integer
      add :acquired_at, :utc_datetime_usec
      add :expired_at, :utc_datetime_usec
      add :last_mutation_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:inventory_items, [:account_id])
    create index(:inventory_items, [:ingredient_id])
    create index(:inventory_items, [:expired_at])
    create index(:inventory_items, [:account_id, :ingredient_id, :unit, :source_kind])

    create constraint(:inventory_items, :inventory_items_unit_check,
             check: "unit IN ('g', 'ml', 'unit')"
           )

    create constraint(:inventory_items, :inventory_items_source_kind_check,
             check: "source_kind IN ('planned', 'extra')"
           )

    create constraint(:inventory_items, :inventory_items_quantity_non_negative,
             check: "quantity_milli >= 0"
           )

    create constraint(:inventory_items, :inventory_items_price_non_negative,
             check: "acquired_price_cents IS NULL OR acquired_price_cents >= 0"
           )

    create table(:inventory_mutation_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :inventory_item_id,
          references(:inventory_items, type: :binary_id, on_delete: :delete_all),
          null: false

      add :trigger_type, :string, null: false
      add :operation, :string, null: false
      add :quantity_before_milli, :integer, null: false
      add :quantity_delta_milli, :integer, null: false
      add :quantity_after_milli, :integer, null: false

      add :source_checkout_session_id,
          references(:checkout_sessions, type: :binary_id, on_delete: :nilify_all)

      add :source_cooking_session_id,
          references(:cooking_sessions, type: :binary_id, on_delete: :nilify_all)

      add :source_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :raw_voice_text, :text
      add :metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:inventory_mutation_events, [:account_id])
    create index(:inventory_mutation_events, [:inventory_item_id])
    create index(:inventory_mutation_events, [:source_user_id])
    create index(:inventory_mutation_events, [:trigger_type])
    create index(:inventory_mutation_events, [:inserted_at])

    create constraint(:inventory_mutation_events, :inventory_mutation_events_trigger_check,
             check: "trigger_type IN ('purchase', 'cooking', 'manual', 'voice')"
           )

    create constraint(:inventory_mutation_events, :inventory_mutation_events_operation_check,
             check: "operation IN ('add', 'subtract', 'set', 'delete')"
           )
  end
end
