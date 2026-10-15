defmodule MealPlannerApi.Repo.Migrations.CreateIngredientTags do
  use Ecto.Migration

  def change do
    create table(:ingredient_tags, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:ingredient_id, references(:ingredients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:tag, :string, null: false)
      # "suggested" rows (e.g. AI output) never count until a reviewer accepts them.
      add(:status, :string, null: false)
      add(:reviewed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:ingredient_tags, [:ingredient_id, :tag]))

    create(
      constraint(:ingredient_tags, :ingredient_tags_status_check,
        check: "status IN ('suggested', 'reviewed')"
      )
    )
  end
end
