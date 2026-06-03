defmodule MealPlannerApi.Repo.Migrations.CreateSlotFavorites do
  use Ecto.Migration

  def change do
    create table(:slot_favorites, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :account_id,
        references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :user_id,
        references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:date, :date, null: false)
      add(:slot, :string, null: false)

      add(
        :scheduled_meal_id,
        references(:scheduled_meals, type: :binary_id, on_delete: :delete_all)
      )

      add(
        :recipe_id,
        references(:recipes, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:slot_favorites, [:account_id]))
    create(index(:slot_favorites, [:date]))
    create(index(:slot_favorites, [:user_id]))

    create(unique_index(:slot_favorites, [:account_id, :user_id, :date, :slot]))
    create(index(:slot_favorites, [:account_id, :date]))
  end
end
