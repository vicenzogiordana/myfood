defmodule MealPlannerApi.Persistence.Shopping.RecipePrice do
  @moduledoc """
  Pre-computed price per serving for each recipe.

  Recomputed nightly by `mix price_sync.run` after ingredient_prices are updated.
  Stores a single "best available price" per recipe (minimum across supermarkets).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "recipe_prices" do
    field(:price_per_serving_cents, :integer)
    field(:last_calculated_at, :utc_datetime_usec)

    belongs_to(:recipe, MealPlannerApi.Persistence.Catalog.Recipe)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(recipe_price, attrs) do
    recipe_price
    |> Ecto.Changeset.cast(attrs, [
      :recipe_id,
      :price_per_serving_cents,
      :last_calculated_at
    ])
    |> Ecto.Changeset.validate_required([
      :recipe_id,
      :price_per_serving_cents,
      :last_calculated_at
    ])
    |> Ecto.Changeset.validate_number(:price_per_serving_cents, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.unique_constraint(
      :recipe_id,
      name: :recipe_prices_recipe_id_index
    )
  end
end
