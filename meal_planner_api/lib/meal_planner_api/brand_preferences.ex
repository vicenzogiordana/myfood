defmodule MealPlannerApi.BrandPreferences do
  @moduledoc """
  Household Brand Preferences settings (spec #93, user stories 50 and 52).

  A Household may prefer one brand per Ingredient. Brand Preferences are
  disclosed to the planning agent in its instructions (see
  `MealPlannerApi.PlanningAgent.HouseholdContext`); they do not change the
  Purchase. They change only here, from household settings, never from the
  planning chat.

  Any Member of the Household may read or change them; tenancy is enforced
  by the caller passing the Household id resolved from the current
  membership.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Accounts.HouseholdBrandPreference
  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Repo

  @type preference :: %{ingredient_id: Ecto.UUID.t(), ingredient: String.t(), brand: String.t()}

  @doc "The Household's Brand Preferences, ordered by ingredient name."
  @spec list(Ecto.UUID.t()) :: [preference()]
  def list(account_id) do
    from(p in HouseholdBrandPreference,
      join: i in Ingredient,
      on: i.id == p.ingredient_id,
      where: p.account_id == ^account_id,
      order_by: [asc: i.name, asc: i.id],
      select: %{ingredient_id: i.id, ingredient: i.name, brand: p.brand}
    )
    |> Repo.all()
  end

  @doc """
  Sets (or replaces) the Household's preferred `brand` for `ingredient_id`.
  The brand is trimmed and must not be blank; the ingredient must exist.
  """
  @spec put(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, preference()} | {:error, Ecto.Changeset.t()}
  def put(account_id, ingredient_id, brand) do
    %HouseholdBrandPreference{}
    |> HouseholdBrandPreference.changeset(%{
      account_id: account_id,
      ingredient_id: ingredient_id,
      brand: brand
    })
    |> Repo.insert(
      on_conflict: {:replace, [:brand, :updated_at]},
      conflict_target: [:account_id, :ingredient_id],
      returning: true
    )
    |> case do
      {:ok, preference} ->
        name =
          Repo.one!(
            from(i in Ingredient, where: i.id == ^preference.ingredient_id, select: i.name)
          )

        {:ok,
         %{ingredient_id: preference.ingredient_id, ingredient: name, brand: preference.brand}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Removes the Household's Brand Preference for `ingredient_id`, if any."
  @spec delete(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def delete(account_id, ingredient_id) do
    {_count, _} =
      from(p in HouseholdBrandPreference,
        where: p.account_id == ^account_id and p.ingredient_id == ^ingredient_id
      )
      |> Repo.delete_all()

    :ok
  end
end
