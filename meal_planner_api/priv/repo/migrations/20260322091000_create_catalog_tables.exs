defmodule MealPlannerApi.Repo.Migrations.CreateCatalogTables do
  use Ecto.Migration

  def change do
    create table(:ingredients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :category, :string, null: false
      add :sku_reference, :string

      add :calories_per_100, :integer
      add :protein_g_per_100, :decimal, precision: 10, scale: 2
      add :carbs_g_per_100, :decimal, precision: 10, scale: 2
      add :fat_g_per_100, :decimal, precision: 10, scale: 2

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ingredients, [:name])
    create index(:ingredients, [:category])

    create constraint(:ingredients, :ingredients_category_check,
             check:
               "category IN ('lacteos', 'frutas', 'verduras', 'carnes', 'granos', 'congelados', 'no_perecederos', 'otros')"
           )

    create table(:recipes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :nilify_all)

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :name, :string, null: false
      add :description, :text
      add :prep_time_minutes, :integer
      add :cook_time_minutes, :integer
      add :servings, :integer
      add :source, :string, null: false, default: "user_created"

      add :calories_per_serving, :integer
      add :protein_g_per_serving, :decimal, precision: 10, scale: 2
      add :carbs_g_per_serving, :decimal, precision: 10, scale: 2
      add :fat_g_per_serving, :decimal, precision: 10, scale: 2

      add :suitable_for_slots, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:recipes, [:account_id])
    create index(:recipes, [:created_by_user_id])
    create index(:recipes, [:source])

    create constraint(:recipes, :recipes_source_check,
             check: "source IN ('traditional', 'ai_generated', 'user_created')"
           )

    create constraint(:recipes, :recipes_slots_allowed_check,
             check:
               "suitable_for_slots <@ ARRAY['breakfast','lunch','snack','dinner']::varchar[]"
           )

    create table(:recipe_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :recipe_id,
          references(:recipes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :step_number, :integer, null: false
      add :instructions, :text, null: false
      add :duration_minutes, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:recipe_steps, [:recipe_id])
    create unique_index(:recipe_steps, [:recipe_id, :step_number])

    create table(:recipe_ingredients, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :recipe_id,
          references(:recipes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :ingredient_id,
          references(:ingredients, type: :binary_id, on_delete: :restrict),
          null: false

      add :quantity_milli, :integer, null: false
      add :unit, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:recipe_ingredients, [:recipe_id])
    create index(:recipe_ingredients, [:ingredient_id])
    create unique_index(:recipe_ingredients, [:recipe_id, :ingredient_id, :unit])

    create constraint(:recipe_ingredients, :recipe_ingredients_unit_check,
             check: "unit IN ('g', 'ml', 'unit')"
           )

    create constraint(:recipe_ingredients, :recipe_ingredients_quantity_positive,
             check: "quantity_milli > 0"
           )

    create table(:recipe_daily_costs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :recipe_id,
          references(:recipes, type: :binary_id, on_delete: :delete_all),
          null: false

      # FK to supermarkets is added in Context 4 to keep migration order stable.
      add :supermarket_id, :binary_id, null: false

      add :total_cents_ars, :integer, null: false
      add :date, :date, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:recipe_daily_costs, [:recipe_id])
    create index(:recipe_daily_costs, [:supermarket_id])
    create index(:recipe_daily_costs, [:date])
    create unique_index(:recipe_daily_costs, [:recipe_id, :supermarket_id, :date])

    create constraint(:recipe_daily_costs, :recipe_daily_costs_total_non_negative,
             check: "total_cents_ars >= 0"
           )
  end
end
