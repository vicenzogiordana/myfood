defmodule MealPlannerApi.Repo.Migrations.CreateHouseholdBrandPreferences do
  use Ecto.Migration

  # Brand Preferences: a Household Preference for a brand of an Ingredient,
  # kept in household settings (spec #93, issue #101). At most one brand per
  # Household and Ingredient.
  def change do
    create table(:household_brand_preferences, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:ingredient_id, references(:ingredients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:brand, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:household_brand_preferences, [:account_id, :ingredient_id]))

    create(
      constraint(:household_brand_preferences, :household_brand_preferences_brand_present,
        check: "btrim(brand) <> ''"
      )
    )
  end
end
