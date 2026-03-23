defmodule MealPlannerApi.Persistence.Catalog.RecipeStep do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "recipe_steps" do
    field(:step_number, :integer)
    field(:instructions, :string)
    field(:duration_minutes, :integer)

    belongs_to(:recipe, MealPlannerApi.Persistence.Catalog.Recipe)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:recipe_id, :step_number, :instructions, :duration_minutes])
    |> validate_required([:recipe_id, :step_number, :instructions])
    |> validate_number(:step_number, greater_than: 0)
    |> validate_number(:duration_minutes, greater_than_or_equal_to: 0)
    |> unique_constraint([:recipe_id, :step_number])
    |> foreign_key_constraint(:recipe_id)
  end
end
