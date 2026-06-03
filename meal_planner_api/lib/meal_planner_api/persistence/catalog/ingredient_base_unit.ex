defmodule MealPlannerApi.Persistence.Catalog.IngredientBaseUnit do
  @moduledoc """
  Canonical (base) unit for an ingredient.

  When the Go scraper returns prices in any unit, we convert them to this base
  unit before storing in `ingredient_prices`. This lets us compare prices fairly
  regardless of package size.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ingredient_base_units" do
    field(:base_unit, :string)

    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "All units currently used in the system."
  @known_units ~w(kg g l ml unit bunch pack)
  def known_units, do: @known_units

  def changeset(base_unit, attrs) do
    base_unit
    |> Ecto.Changeset.cast(attrs, [:ingredient_id, :base_unit])
    |> Ecto.Changeset.validate_required([:ingredient_id, :base_unit])
    |> Ecto.Changeset.validate_inclusion(:base_unit, @known_units)
    |> Ecto.Changeset.unique_constraint(:ingredient_id)
    |> Ecto.Changeset.foreign_key_constraint(:ingredient_id)
  end
end
