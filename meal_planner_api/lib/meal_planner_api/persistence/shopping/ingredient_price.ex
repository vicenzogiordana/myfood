defmodule MealPlannerApi.Persistence.Shopping.IngredientPrice do
  @moduledoc """
  Latest price snapshot per (ingredient, supermarket) pair.

  Written nightly by `mix price_sync.run` after querying the Go scraper API.
  This is a denormalized "latest only" table — it replaces the previous price
  on each sync. Historical prices live in SupermarketCatalog.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ingredient_prices" do
    field(:supermarket_id, :string)
    field(:price_per_unit_cents, :integer)
    field(:unit, :string)
    field(:scraped_at, :utc_datetime_usec)

    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Units supported by the Go scraper price API."
  @valid_units ~w(kg g l ml unit bunch pack)
  def valid_units, do: @valid_units

  def changeset(ingredient_price, attrs) do
    ingredient_price
    |> Ecto.Changeset.cast(attrs, [
      :ingredient_id,
      :supermarket_id,
      :price_per_unit_cents,
      :unit,
      :scraped_at
    ])
    |> Ecto.Changeset.validate_required([
      :ingredient_id,
      :supermarket_id,
      :price_per_unit_cents,
      :unit,
      :scraped_at
    ])
    |> Ecto.Changeset.validate_number(:price_per_unit_cents, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_inclusion(:unit, @valid_units)
    |> Ecto.Changeset.unique_constraint(
      [:ingredient_id, :supermarket_id],
      name: :ingredient_prices_ingredient_id_supermarket_id_index
    )
  end
end
