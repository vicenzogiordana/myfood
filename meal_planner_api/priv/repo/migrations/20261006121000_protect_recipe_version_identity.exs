defmodule MealPlannerApi.Repo.Migrations.ProtectRecipeVersionIdentity do
  use Ecto.Migration

  def up do
    execute(
      "CREATE TRIGGER immutable_recipe_version_delete BEFORE DELETE ON recipe_versions FOR EACH ROW EXECUTE FUNCTION prevent_recipe_version_update()"
    )

    execute("""
    CREATE FUNCTION protect_confirmed_meal_account() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.account_id IS DISTINCT FROM NEW.account_id THEN
        RAISE EXCEPTION 'confirmed meal Account is immutable';
      END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE TRIGGER protect_confirmed_meal_account BEFORE UPDATE OF account_id ON scheduled_meals FOR EACH ROW EXECUTE FUNCTION protect_confirmed_meal_account()"
    )
  end

  def down do
    execute("DROP TRIGGER protect_confirmed_meal_account ON scheduled_meals")
    execute("DROP FUNCTION protect_confirmed_meal_account()")
    execute("DROP TRIGGER immutable_recipe_version_delete ON recipe_versions")
  end
end
