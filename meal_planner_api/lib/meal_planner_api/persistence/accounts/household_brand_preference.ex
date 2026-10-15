defmodule MealPlannerApi.Persistence.Accounts.HouseholdBrandPreference do
  @moduledoc """
  A Brand Preference: a Household Preference for a brand of an Ingredient,
  kept in household settings (spec #93). At most one per Household and
  Ingredient. It is a soft preference, never a Restriction.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_brand_length 120

  schema "household_brand_preferences" do
    field(:brand, :string)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:account_id, :ingredient_id, :brand])
    |> update_change(:brand, &single_line/1)
    |> validate_required([:account_id, :ingredient_id, :brand])
    |> validate_length(:brand, max: @max_brand_length)
    |> validate_format(:brand, ~r/\A[^\p{C}]+\z/u)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:ingredient_id)
    |> unique_constraint([:account_id, :ingredient_id])
  end

  @doc """
  Collapses every whitespace run (line breaks included) into one space and
  trims. The brand is Member-authored text that reaches the agent
  instructions, so it must never span lines (it could forge directives).
  """
  def single_line(brand) when is_binary(brand),
    do: ~r/\s+/u |> Regex.replace(brand, " ") |> String.trim()
end
