defmodule MealPlannerApi.Persistence.Catalog.RecipeIngredient do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "recipe_ingredients" do
    field(:quantity_milli, :integer)
    field(:unit, Ecto.Enum, values: [:g, :ml, :unit])

    belongs_to(:recipe, MealPlannerApi.Persistence.Catalog.Recipe)
    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(recipe_ingredient, attrs) do
    recipe_ingredient
    |> cast(attrs, [:recipe_id, :ingredient_id, :quantity_milli, :unit])
    |> validate_required([:recipe_id, :ingredient_id, :quantity_milli, :unit])
    |> validate_number(:quantity_milli, greater_than: 0)
    |> unique_constraint([:recipe_id, :ingredient_id, :unit])
    |> foreign_key_constraint(:recipe_id)
    |> foreign_key_constraint(:ingredient_id)
  end
end
