defmodule MealPlannerApi.Persistence.Catalog.UnitConversion do
  @moduledoc """
  Conversion factor from a raw scraped unit to the ingredient's base unit.

  Example row:
    ingredient_id = "pollo"
    from_unit = "g"
    factor_to_base = 0.001   # 1g = 0.001kg (base unit for chicken)

  Without a conversion row for a given (ingredient, from_unit) pair, the scraper
  output for that ingredient/unit is skipped.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "unit_conversions" do
    field(:from_unit, :string)
    field(:factor_to_base, :float)

    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conversion, attrs) do
    conversion
    |> Ecto.Changeset.cast(attrs, [:ingredient_id, :from_unit, :factor_to_base])
    |> Ecto.Changeset.validate_required([:ingredient_id, :from_unit, :factor_to_base])
    |> Ecto.Changeset.validate_number(:factor_to_base, greater_than: 0)
    |> Ecto.Changeset.unique_constraint([:ingredient_id, :from_unit])
    |> Ecto.Changeset.foreign_key_constraint(:ingredient_id)
  end
end
