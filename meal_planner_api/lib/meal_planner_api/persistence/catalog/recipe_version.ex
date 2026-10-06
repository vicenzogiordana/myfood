defmodule MealPlannerApi.Persistence.Catalog.RecipeVersion do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "recipe_versions" do
    belongs_to(:recipe, MealPlannerApi.Persistence.Catalog.Recipe)
    belongs_to(:predecessor, __MODULE__)
    field(:number, :integer)
    field(:snapshot, :map)
    timestamps(type: :utc_datetime_usec)
  end
end
