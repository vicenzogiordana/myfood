defmodule MealPlannerApi.Repo.Migrations.CreateUserDietaryProfilesAndUserExcludedIngredients do
  use Ecto.Migration

  def change do
    create table(:user_dietary_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :diet_type, :string, null: false
      add :macro_goal, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_dietary_profiles, [:user_id])

    create constraint(:user_dietary_profiles, :user_dietary_profiles_diet_type_check,
             check: "diet_type IN ('omnivore', 'vegetarian', 'vegan', 'pescatarian', 'celiac')"
           )

    create constraint(:user_dietary_profiles, :user_dietary_profiles_macro_goal_check,
             check:
               "macro_goal IN ('balanced', 'high_protein', 'low_carb', 'high_calorie', 'low_calorie')"
           )

    create table(:user_excluded_ingredients, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      # FK to ingredients is added in Context 2 to keep migration order stable.
      add :ingredient_id, :binary_id, null: false
      add :reason, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_excluded_ingredients, [:user_id])
    create index(:user_excluded_ingredients, [:ingredient_id])
    create unique_index(:user_excluded_ingredients, [:user_id, :ingredient_id])

    create constraint(:user_excluded_ingredients, :user_excluded_ingredients_reason_check,
             check: "reason IN ('allergy', 'dislike')"
           )
  end
end
