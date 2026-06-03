defmodule MealPlannerApi.Data.UserPreferenceRepo do
  @moduledoc """
  Pure data access for user_preferences.

  No business logic. Creates on first access (upsert pattern).
  """

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Accounts.UserPreference

  @spec get(pos_integer()) :: UserPreference.t() | nil
  def get(user_id) do
    Repo.get_by(UserPreference, user_id: user_id)
  end

  @spec get!(pos_integer()) :: UserPreference.t()
  def get!(user_id) do
    Repo.get_by!(UserPreference, user_id: user_id)
  end

  @spec upsert(pos_integer(), map()) :: {:ok, UserPreference.t()} | {:error, Ecto.Changeset.t()}
  def upsert(user_id, attrs) when is_map(attrs) do
    case Repo.get_by(UserPreference, user_id: user_id) do
      nil ->
        %UserPreference{user_id: user_id}
        |> UserPreference.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> UserPreference.changeset(attrs)
        |> Repo.update()
    end
  end

  @spec delete(pos_integer()) :: {:ok, UserPreference.t()} | {:error, term()}
  def delete(user_id) do
    case Repo.get_by(UserPreference, user_id: user_id) do
      nil -> {:error, :not_found}
      pref -> Repo.delete(pref)
    end
  end
end
