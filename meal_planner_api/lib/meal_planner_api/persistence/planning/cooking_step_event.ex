defmodule MealPlannerApi.Persistence.Planning.CookingStepEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cooking_step_events" do
    field(:event_type, Ecto.Enum, values: [:started, :paused, :completed, :error])
    field(:event_at, :utc_datetime_usec)

    belongs_to(:cooking_session, MealPlannerApi.Persistence.Planning.CookingSession)
    belongs_to(:recipe_step, MealPlannerApi.Persistence.Catalog.RecipeStep)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(step_event, attrs) do
    step_event
    |> cast(attrs, [:cooking_session_id, :recipe_step_id, :event_type, :event_at])
    |> validate_required([:cooking_session_id, :recipe_step_id, :event_type, :event_at])
    |> foreign_key_constraint(:cooking_session_id)
    |> foreign_key_constraint(:recipe_step_id)
  end
end
