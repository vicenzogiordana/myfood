defmodule MealPlannerApi.Repo.Migrations.AddIngredientNameSimilarity do
  @moduledoc """
  Similarity search over Ingredient names (issue #160): `pg_trgm` trigram
  similarity over unaccented, lowercased names, so "mozzarella" finds
  "Muzzarella" and "limon" finds "Limón".

  `unaccent` is only STABLE, so an index cannot use it directly:
  `ingredient_search_key/1` wraps it with an explicit dictionary as an
  IMMUTABLE function, and the GIN trigram index is built over that key.
  The extensions stay on rollback, since other objects may use them.
  """

  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    execute("CREATE EXTENSION IF NOT EXISTS unaccent")

    execute("""
    CREATE OR REPLACE FUNCTION ingredient_search_key(text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$ SELECT public.unaccent('public.unaccent'::regdictionary, lower($1)) $$
    """)

    execute("""
    CREATE INDEX ingredients_name_trgm_index
    ON ingredients USING gin (ingredient_search_key(name) gin_trgm_ops)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS ingredients_name_trgm_index")
    execute("DROP FUNCTION IF EXISTS ingredient_search_key(text)")
  end
end
