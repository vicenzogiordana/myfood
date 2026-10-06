defmodule MealPlannerApi.Repo.Migrations.FreezeRecipeVersions do
  use Ecto.Migration

  def up do
    alter table(:recipes) do
      add(:superseded_by_id, references(:recipes, type: :binary_id, on_delete: :nilify_all))
    end

    create table(:recipe_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:recipe_id, references(:recipes, type: :binary_id, on_delete: :delete_all), null: false)
      add(:predecessor_id, references(:recipe_versions, type: :binary_id), null: true)
      add(:number, :integer, null: false, default: 1)
      add(:snapshot, :map, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:recipe_versions, [:recipe_id]))
    create(unique_index(:recipe_versions, [:predecessor_id]))

    alter table(:scheduled_meals) do
      add(:recipe_version_id, references(:recipe_versions, type: :binary_id))
      add(:recipe_snapshot, :map)
      add(:selected_quantity, :integer, null: false, default: 1)
    end

    create(
      constraint(:scheduled_meals, :positive_selected_quantity, check: "selected_quantity > 0")
    )

    flush()

    # Locking the recipe serializes first publication with corrections. Each version
    # has its own recipe row, so existing proposal recipe IDs remain pinned.
    execute("""
    CREATE FUNCTION freeze_recipe_version(recipe_uuid uuid) RETURNS uuid LANGUAGE plpgsql AS $$
    DECLARE version_uuid uuid; recipe_row recipes%ROWTYPE; document jsonb;
    BEGIN
      SELECT * INTO recipe_row FROM recipes WHERE id = recipe_uuid FOR UPDATE;
      IF NOT FOUND THEN RETURN NULL; END IF;
      SELECT id INTO version_uuid FROM recipe_versions WHERE recipe_id = recipe_uuid;
      IF FOUND THEN RETURN version_uuid; END IF;
      document := (to_jsonb(recipe_row) - ARRAY['inserted_at','updated_at','superseded_by_id']) ||
        jsonb_build_object(
          'recipe_steps', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'id', s.id, 'step_number', s.step_number, 'instructions', s.instructions,
            'duration_minutes', s.duration_minutes) ORDER BY s.step_number)
            FROM recipe_steps s WHERE s.recipe_id = recipe_uuid), '[]'::jsonb),
          'recipe_ingredients', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'id', ri.id, 'ingredient_id', ri.ingredient_id, 'quantity_milli', ri.quantity_milli,
            'unit', ri.unit, 'ingredient', jsonb_build_object('id', i.id, 'name', i.name)) ORDER BY ri.id)
            FROM recipe_ingredients ri JOIN ingredients i ON i.id = ri.ingredient_id
            WHERE ri.recipe_id = recipe_uuid), '[]'::jsonb),
          'estimated_cost_cents', COALESCE((SELECT total_cents_ars FROM recipe_daily_costs
            WHERE recipe_id = recipe_uuid ORDER BY date DESC, inserted_at DESC LIMIT 1), 0));
      version_uuid := gen_random_uuid();
      INSERT INTO recipe_versions (id, recipe_id, number, snapshot, inserted_at, updated_at)
        VALUES (version_uuid, recipe_uuid, 1, document, now(), now());
      RETURN version_uuid;
    END $$
    """)

    execute("SELECT freeze_recipe_version(id) FROM recipes ORDER BY id")

    execute("""
    UPDATE scheduled_meals m SET recipe_version_id = v.id,
      recipe_snapshot = v.snapshot || jsonb_build_object('selected_quantity', m.selected_quantity)
    FROM recipe_versions v WHERE v.recipe_id = m.recipe_id
    """)

    execute("""
    CREATE FUNCTION freeze_scheduled_recipe() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE version_uuid uuid;
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.recipe_id IS NOT DISTINCT FROM NEW.recipe_id THEN
        IF OLD.recipe_snapshot IS DISTINCT FROM NEW.recipe_snapshot OR
           OLD.recipe_version_id IS DISTINCT FROM NEW.recipe_version_id OR
           OLD.selected_quantity IS DISTINCT FROM NEW.selected_quantity THEN
          RAISE EXCEPTION 'confirmed recipe snapshot is immutable';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.recipe_id IS NULL THEN
        NEW.recipe_version_id := NULL; NEW.recipe_snapshot := NULL;
      ELSE
        IF NOT EXISTS (SELECT 1 FROM recipes WHERE id = NEW.recipe_id
                       AND (account_id IS NULL OR account_id = NEW.account_id)) THEN
          RAISE EXCEPTION 'recipe does not belong to Account';
        END IF;
        version_uuid := freeze_recipe_version(NEW.recipe_id);
        NEW.recipe_version_id := version_uuid;
        SELECT snapshot || jsonb_build_object('selected_quantity', NEW.selected_quantity)
          INTO NEW.recipe_snapshot FROM recipe_versions WHERE id = version_uuid;
      END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE TRIGGER freeze_scheduled_recipe BEFORE INSERT OR UPDATE ON scheduled_meals FOR EACH ROW EXECUTE FUNCTION freeze_scheduled_recipe()"
    )

    # Proposal publication freezes recipe IDs before a later correction can occur.
    execute("""
    CREATE FUNCTION freeze_proposal_recipes() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE item jsonb; recipe_uuid uuid;
    BEGIN
      FOR item IN SELECT value FROM jsonb_array_elements(
        COALESCE(NEW.proposal_json->'slots', NEW.proposal_json->'meals', '[]'::jsonb)) LOOP
        IF item->>'recipe_id' IS NOT NULL THEN
          BEGIN recipe_uuid := (item->>'recipe_id')::uuid;
          EXCEPTION WHEN invalid_text_representation THEN CONTINUE; END;
          PERFORM freeze_recipe_version(recipe_uuid);
        END IF;
      END LOOP;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE TRIGGER freeze_proposal_recipes BEFORE INSERT OR UPDATE OF proposal_json ON planning_proposals FOR EACH ROW EXECUTE FUNCTION freeze_proposal_recipes()"
    )

    execute("""
    CREATE FUNCTION prevent_recipe_version_update() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'recipe versions are immutable'; END $$
    """)

    execute(
      "CREATE TRIGGER immutable_recipe_version BEFORE UPDATE ON recipe_versions FOR EACH ROW EXECUTE FUNCTION prevent_recipe_version_update()"
    )
  end

  def down do
    execute("DROP TRIGGER freeze_proposal_recipes ON planning_proposals")
    execute("DROP FUNCTION freeze_proposal_recipes()")
    execute("DROP TRIGGER freeze_scheduled_recipe ON scheduled_meals")
    execute("DROP FUNCTION freeze_scheduled_recipe()")
    execute("DROP FUNCTION freeze_recipe_version(uuid)")
    execute("DROP TRIGGER immutable_recipe_version ON recipe_versions")
    execute("DROP FUNCTION prevent_recipe_version_update()")

    alter table(:scheduled_meals) do
      remove(:recipe_version_id)
      remove(:recipe_snapshot)
      remove(:selected_quantity)
    end

    drop(table(:recipe_versions))
    alter(table(:recipes), do: remove(:superseded_by_id))
  end
end
