defmodule MealPlannerApi.Persistence.Accounts.UserDietaryProfile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_dietary_profiles" do
    field(:diet_type, Ecto.Enum, values: [:omnivore, :vegetarian, :vegan, :pescatarian, :celiac])

    field(:macro_goal, Ecto.Enum,
      values: [:balanced, :high_protein, :low_carb, :high_calorie, :low_calorie]
    )

    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:user_id, :diet_type, :macro_goal])
    |> validate_required([:user_id, :diet_type, :macro_goal])
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
