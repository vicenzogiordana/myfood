defmodule MealPlannerApi.Repo.Migrations.CreateIngredientPrices do
  use Ecto.Migration

  def change do
    create table(:ingredient_prices, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :ingredient_id,
        references(:ingredients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:supermarket_id, :string, null: false)

      add(:price_per_unit_cents, :integer, null: false)

      add(:unit, :string, null: false)

      add(:scraped_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:ingredient_prices, [:ingredient_id]))
    create(index(:ingredient_prices, [:scraped_at]))
    create(unique_index(:ingredient_prices, [:ingredient_id, :supermarket_id]))
  end
end
