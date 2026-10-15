defmodule MealPlannerApi.Repo.Migrations.CreateHouseholdNutritionGoals do
  use Ecto.Migration

  @bounds ~w(calories protein_g carbs_g fat_g)a

  def change do
    create table(:household_nutrition_goals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      for bound <- @bounds do
        add(:"#{bound}_min", :integer, null: false)
        add(:"#{bound}_max", :integer, null: false)
      end

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:household_nutrition_goals, [:account_id]))

    for bound <- @bounds do
      create(
        constraint(:household_nutrition_goals, :"#{bound}_range_valid",
          check: "#{bound}_min >= 0 AND #{bound}_min <= #{bound}_max"
        )
      )
    end
  end
end
