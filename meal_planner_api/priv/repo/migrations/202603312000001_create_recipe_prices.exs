defmodule MealPlannerApi.Repo.Migrations.CreateRecipePrices do
  use Ecto.Migration

  def change do
    create table(:recipe_prices, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :recipe_id,
        references(:recipes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:price_per_serving_cents, :integer, null: false)

      add(:last_calculated_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:recipe_prices, [:recipe_id]))
    create(index(:recipe_prices, [:last_calculated_at]))
  end
end
