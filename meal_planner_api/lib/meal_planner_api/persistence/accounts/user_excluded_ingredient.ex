defmodule MealPlannerApi.Persistence.Accounts.UserExcludedIngredient do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_excluded_ingredients" do
    field(:reason, Ecto.Enum, values: [:allergy, :dislike])

    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)
    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(exclusion, attrs) do
    exclusion
    |> cast(attrs, [:user_id, :ingredient_id, :reason])
    |> validate_required([:user_id, :ingredient_id, :reason])
    |> unique_constraint([:user_id, :ingredient_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:ingredient_id)
  end
end
