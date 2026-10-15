defmodule MealPlannerApi.Persistence.Shopping.Product do
  @moduledoc """
  A specific supermarket article covering an Ingredient, with its brand and
  package size (its presentation). Purchases are made of whole packages of
  Products (spec #93).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "products" do
    field(:name, :string)
    field(:brand, :string)
    field(:package_quantity_milli, :integer)
    field(:package_unit, Ecto.Enum, values: [:g, :ml, :unit])

    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)
    belongs_to(:supermarket, MealPlannerApi.Persistence.Shopping.Supermarket)

    has_many(:price_observations, MealPlannerApi.Persistence.Shopping.PriceObservation)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [
      :ingredient_id,
      :supermarket_id,
      :name,
      :brand,
      :package_quantity_milli,
      :package_unit
    ])
    |> validate_required([
      :ingredient_id,
      :supermarket_id,
      :name,
      :package_quantity_milli,
      :package_unit
    ])
    |> validate_number(:package_quantity_milli, greater_than: 0)
    |> foreign_key_constraint(:ingredient_id)
    |> foreign_key_constraint(:supermarket_id)
    |> unique_constraint([
      :supermarket_id,
      :ingredient_id,
      :name,
      :package_quantity_milli,
      :package_unit
    ])
  end
end
