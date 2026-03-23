defmodule MealPlannerApi.Persistence.Planning.ContextSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "context_snapshots" do
    field(:snapshot_data, :map)
    field(:captured_at, :utc_datetime_usec)

    belongs_to(:cooking_session, MealPlannerApi.Persistence.Planning.CookingSession)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:cooking_session_id, :snapshot_data, :captured_at])
    |> validate_required([:cooking_session_id, :snapshot_data, :captured_at])
    |> foreign_key_constraint(:cooking_session_id)
  end
end
