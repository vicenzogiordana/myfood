defmodule MealPlannerApi.Repo.Migrations.CreateFavoriteRecipes do
  use Ecto.Migration

  def change do
    create table(:favorite_recipes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :recipe_id,
          references(:recipes, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:favorite_recipes, [:account_id])
    create index(:favorite_recipes, [:user_id])
    create index(:favorite_recipes, [:recipe_id])
    create unique_index(:favorite_recipes, [:account_id, :user_id, :recipe_id])
  end
end
