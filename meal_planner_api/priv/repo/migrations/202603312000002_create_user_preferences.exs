defmodule MealPlannerApi.Repo.Migrations.CreateUserPreferences do
  use Ecto.Migration

  def change do
    create table(:user_preferences, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :user_id,
        references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:protein_g_per_meal, :integer)

      add(:default_exclusions, {:array, :string})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:user_preferences, [:user_id]))
  end
end
