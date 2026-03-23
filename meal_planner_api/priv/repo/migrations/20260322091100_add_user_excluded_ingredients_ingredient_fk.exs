defmodule MealPlannerApi.Repo.Migrations.AddUserExcludedIngredientsIngredientFk do
  use Ecto.Migration

  def change do
    alter table(:user_excluded_ingredients) do
      modify :ingredient_id,
             references(:ingredients, type: :binary_id, on_delete: :restrict),
             from: :binary_id,
             null: false
    end
  end
end
