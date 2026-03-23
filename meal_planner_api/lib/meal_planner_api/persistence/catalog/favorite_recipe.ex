defmodule MealPlannerApi.Persistence.Catalog.FavoriteRecipe do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "favorite_recipes" do
    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)
    belongs_to(:recipe, MealPlannerApi.Persistence.Catalog.Recipe)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(favorite, attrs) do
    favorite
    |> cast(attrs, [:account_id, :user_id, :recipe_id])
    |> validate_required([:account_id, :user_id, :recipe_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:recipe_id)
    |> unique_constraint([:account_id, :user_id, :recipe_id])
  end
end
