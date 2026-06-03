defmodule MealPlannerApi.Repo.Migrations.CreateUnitConversionTables do
  use Ecto.Migration

  def change do
    # -----------------------------------------------------------------------------
    # ingredient_base_units: canonical unit per ingredient (kg, l, unit, etc.)
    # -----------------------------------------------------------------------------
    create table(:ingredient_base_units, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :ingredient_id,
        references(:ingredients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:base_unit, :string, null: false)
      # e.g. "kg" for pollo, "l" for leche, "unit" for huevos

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:ingredient_base_units, [:ingredient_id]))

    # -----------------------------------------------------------------------------
    # unit_conversions: how to convert Go-scraper units to the base unit
    # -----------------------------------------------------------------------------
    create table(:unit_conversions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :ingredient_id,
        references(:ingredients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # The unit string returned by the Go scraper API (e.g. "g", "ml", "u")
      add(:from_unit, :string, null: false)

      # Multiplier to convert from_unit → base_unit
      # e.g. 0.001  when base_unit="kg" and from_unit="g"
      # e.g. 0.2    when base_unit="kg" and from_unit="200g"
      # e.g. 1.0    when base_unit="kg" and from_unit="kg"
      add(:factor_to_base, :float, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:unit_conversions, [:ingredient_id, :from_unit]))
    create(index(:unit_conversions, [:ingredient_id]))
  end
end
