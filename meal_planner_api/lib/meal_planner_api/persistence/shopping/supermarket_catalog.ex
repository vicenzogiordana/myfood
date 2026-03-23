defmodule MealPlannerApi.Persistence.Shopping.SupermarketCatalog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "supermarket_catalogs" do
    field(:price_cents_ars, :integer)
    field(:unit, :string)
    field(:price_date, :date)
    field(:last_scraped_at, :utc_datetime_usec)

    belongs_to(:supermarket, MealPlannerApi.Persistence.Shopping.Supermarket)
    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(catalog, attrs) do
    catalog
    |> cast(attrs, [
      :supermarket_id,
      :ingredient_id,
      :price_cents_ars,
      :unit,
      :price_date,
      :last_scraped_at
    ])
    |> validate_required([:supermarket_id, :ingredient_id, :price_cents_ars, :unit, :price_date])
    |> validate_number(:price_cents_ars, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:supermarket_id)
    |> foreign_key_constraint(:ingredient_id)
    |> unique_constraint([:supermarket_id, :ingredient_id, :price_date])
  end
end
