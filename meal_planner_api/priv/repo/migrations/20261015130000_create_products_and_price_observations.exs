defmodule MealPlannerApi.Repo.Migrations.CreateProductsAndPriceObservations do
  use Ecto.Migration

  # Products are specific supermarket articles covering an Ingredient, with
  # their brand and package size (presentation). Price Observations are the
  # price of a Product with its currency and when it was observed (spec #93).
  def change do
    create table(:products, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:ingredient_id, references(:ingredients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:supermarket_id, references(:supermarkets, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:brand, :string)
      add(:package_quantity_milli, :bigint, null: false)
      add(:package_unit, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:products, [:ingredient_id]))

    create(
      unique_index(:products, [
        :supermarket_id,
        :ingredient_id,
        :name,
        :package_quantity_milli,
        :package_unit
      ])
    )

    create(
      constraint(:products, :products_package_quantity_positive,
        check: "package_quantity_milli > 0"
      )
    )

    create(
      constraint(:products, :products_package_unit_check, check: "package_unit IN ('g', 'ml', 'unit')")
    )

    create table(:price_observations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:price_cents, :bigint, null: false)
      add(:currency, :string, size: 3, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:price_observations, [:product_id, :observed_at]))

    create(
      constraint(:price_observations, :price_observations_price_non_negative,
        check: "price_cents >= 0"
      )
    )
  end
end
