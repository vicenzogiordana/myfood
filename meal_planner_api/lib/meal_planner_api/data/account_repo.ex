defmodule MealPlannerApi.Data.AccountRepo do
  @moduledoc """
  Pure data access for accounts, users, and subscription state.

  No business logic. No orchestration. Just queries and persistence.
  """

  import Ecto.Query, warn: false
  alias MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Accounts.{
    Account,
    User,
    UserDietaryProfile,
    UserExcludedIngredient
  }

  # -------------------------------------------------------------------------
  # Accounts
  # -------------------------------------------------------------------------

  @spec create_account(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_account(attrs),
    do: %Account{} |> Account.changeset(attrs) |> Repo.insert()

  @spec get_account!(pos_integer()) :: Account.t()
  def get_account!(id), do: Repo.get!(Account, id)

  @spec get_account(pos_integer()) :: Account.t() | nil
  def get_account(id), do: Repo.get(Account, id)

  @spec get_account_with_users!(pos_integer()) :: Account.t()
  def get_account_with_users!(id) do
    Account
    |> Repo.get!(id)
    |> Repo.preload(:users)
  end

  @spec update_account(Account.t(), map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def update_account(account, attrs),
    do: account |> Account.changeset(attrs) |> Repo.update()

  # -------------------------------------------------------------------------
  # Users
  # -------------------------------------------------------------------------

  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs), do: %User{} |> User.changeset(attrs) |> Repo.insert()

  @spec get_user!(pos_integer()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @spec get_user(pos_integer()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @spec get_user_with_account!(pos_integer()) :: User.t()
  def get_user_with_account!(id) do
    User
    |> Repo.get!(id)
    |> Repo.preload(:account)
  end

  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email), do: Repo.get_by(User, email: email)

  @spec get_user_by_provider(String.t(), String.t()) :: User.t() | nil
  def get_user_by_provider(provider, provider_uid),
    do: Repo.get_by(User, provider: provider, provider_uid: provider_uid)

  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(user, attrs), do: user |> User.changeset(attrs) |> Repo.update()

  @spec find_users_by_ids([pos_integer()]) :: [User.t()]
  def find_users_by_ids(ids) when is_list(ids), do: Repo.all(from(u in User, where: u.id in ^ids))

  # -------------------------------------------------------------------------
  # Dietary profile
  # -------------------------------------------------------------------------

  @spec upsert_dietary_profile(pos_integer(), map()) ::
          {:ok, UserDietaryProfile.t()} | {:error, Ecto.Changeset.t()}
  def upsert_dietary_profile(user_id, attrs) do
    attrs = Map.put(attrs, :user_id, user_id)

    case Repo.get_by(UserDietaryProfile, user_id: user_id) do
      nil -> %UserDietaryProfile{} |> UserDietaryProfile.changeset(attrs) |> Repo.insert()
      profile -> profile |> UserDietaryProfile.changeset(attrs) |> Repo.update()
    end
  end

  @spec get_dietary_profile!(pos_integer()) :: UserDietaryProfile.t()
  def get_dietary_profile!(user_id), do: Repo.get_by!(UserDietaryProfile, user_id: user_id)

  @spec get_dietary_profile(pos_integer()) :: UserDietaryProfile.t() | nil
  def get_dietary_profile(user_id), do: Repo.get_by(UserDietaryProfile, user_id: user_id)

  # -------------------------------------------------------------------------
  # Excluded ingredients
  # -------------------------------------------------------------------------

  @spec add_excluded_ingredient(pos_integer(), pos_integer(), String.t()) ::
          {:ok, UserExcludedIngredient.t()} | {:error, Ecto.Changeset.t()}
  def add_excluded_ingredient(user_id, ingredient_id, reason) do
    attrs = %{user_id: user_id, ingredient_id: ingredient_id, reason: reason}
    %UserExcludedIngredient{} |> UserExcludedIngredient.changeset(attrs) |> Repo.insert()
  end

  @spec remove_excluded_ingredient(pos_integer(), pos_integer()) :: :ok
  def remove_excluded_ingredient(user_id, ingredient_id) do
    from(e in UserExcludedIngredient,
      where: e.user_id == ^user_id and e.ingredient_id == ^ingredient_id
    )
    |> Repo.delete_all()

    :ok
  end

  @spec list_excluded_ingredients(pos_integer()) :: [UserExcludedIngredient.t()]
  def list_excluded_ingredients(user_id) do
    from(e in UserExcludedIngredient,
      where: e.user_id == ^user_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  @spec list_excluded_ingredient_ids([pos_integer()]) :: MapSet.t(pos_integer())
  def list_excluded_ingredient_ids(user_ids) do
    from(e in UserExcludedIngredient,
      where: e.user_id in ^user_ids,
      select: e.ingredient_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end
end
