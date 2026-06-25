defmodule MealPlannerApi.Persistence.Accounts.User do
  @moduledoc """
  User schema — Phase A nullable account_id.

  Per `design.md` §2.3 (decision 5.1) `users.account_id` is relaxed to
  nullable for the dual-write window so that `access_v2` JWT holders can
  carry `current_user.account_id == nil` while `current_membership` carries
  the real tenancy. The schema mirrors the migration: `account_id` is no
  longer in the required list, and a `has_many :memberships` association
  is added (tenancy now flows through `AccountMembership` rows — see
  `account_membership.ex`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field(:email, :string)
    field(:name, :string)
    field(:role, Ecto.Enum, values: [:owner, :member])
    field(:password_hash, :string)
    field(:avatar_url, :string)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    has_many(:memberships, MealPlannerApi.Persistence.Accounts.AccountMembership)
    has_one(:dietary_profile, MealPlannerApi.Persistence.Accounts.UserDietaryProfile)
    has_many(:excluded_ingredients, MealPlannerApi.Persistence.Accounts.UserExcludedIngredient)
    has_one(:revenuecat_customer, MealPlannerApi.Persistence.Accounts.RevenuecatCustomer)
    has_many(:favorite_recipes, MealPlannerApi.Persistence.Catalog.FavoriteRecipe)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts and validates a user changeset. Required fields: email, name,
  role. `account_id` is OPTIONAL during the dual-write window — see the
  module doc and `design.md` §2.3.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:account_id, :email, :name, :role, :password_hash, :avatar_url])
    |> validate_required([:email, :name, :role])
    |> unique_constraint(:email)
    |> foreign_key_constraint(:account_id)
  end
end
