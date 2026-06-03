defmodule MealPlannerApi.Persistence.Accounts.UserPreference do
  @moduledoc """
  User-level planning preferences: protein target and dietary exclusions.

  Stored separately from User so the core User schema stays lean.
  Created or updated on first access or when the user saves preferences.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_preferences" do
    field(:protein_g_per_meal, :integer)
    field(:default_exclusions, {:array, :string}, default: [])

    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(preference, attrs) do
    preference
    |> Ecto.Changeset.cast(attrs, [:user_id, :protein_g_per_meal, :default_exclusions])
    |> Ecto.Changeset.validate_required([:user_id])
    |> Ecto.Changeset.validate_number(:protein_g_per_meal,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 200
    )
    |> Ecto.Changeset.unique_constraint(:user_id)
    |> Ecto.Changeset.foreign_key_constraint(:user_id)
  end
end
