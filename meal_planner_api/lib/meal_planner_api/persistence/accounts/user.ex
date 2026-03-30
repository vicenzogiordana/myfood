defmodule MealPlannerApi.Persistence.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field(:email, :string)
    field(:name, :string)
    field(:role, Ecto.Enum, values: [:owner, :member])
    field(:password_hash, :string)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    has_one(:dietary_profile, MealPlannerApi.Persistence.Accounts.UserDietaryProfile)
    has_many(:excluded_ingredients, MealPlannerApi.Persistence.Accounts.UserExcludedIngredient)
    has_one(:revenuecat_customer, MealPlannerApi.Persistence.Accounts.RevenuecatCustomer)
    has_many(:favorite_recipes, MealPlannerApi.Persistence.Catalog.FavoriteRecipe)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:account_id, :email, :name, :role, :password_hash])
    |> validate_required([:account_id, :email, :name, :role])
    |> unique_constraint(:email)
    |> foreign_key_constraint(:account_id)
  end
end
