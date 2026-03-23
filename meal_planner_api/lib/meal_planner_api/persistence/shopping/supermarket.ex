defmodule MealPlannerApi.Persistence.Shopping.Supermarket do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "supermarkets" do
    field(:name, :string)
    field(:chain, :string)
    field(:pricing_scrape_enabled, :boolean, default: true)
    field(:pricing_scrape_url, :string)
    field(:active_from, :utc_datetime_usec)
    field(:active_until, :utc_datetime_usec)

    has_many(:catalogs, MealPlannerApi.Persistence.Shopping.SupermarketCatalog)

    has_many(:shopping_items, MealPlannerApi.Persistence.Shopping.ShoppingItem,
      foreign_key: :assigned_supermarket_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(supermarket, attrs) do
    supermarket
    |> cast(attrs, [
      :name,
      :chain,
      :pricing_scrape_enabled,
      :pricing_scrape_url,
      :active_from,
      :active_until
    ])
    |> validate_required([:name, :pricing_scrape_enabled])
    |> unique_constraint(:name)
  end
end
