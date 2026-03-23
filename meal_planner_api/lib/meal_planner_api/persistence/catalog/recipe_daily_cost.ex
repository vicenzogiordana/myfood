defmodule MealPlannerApi.Persistence.Catalog.RecipeDailyCost do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "recipe_daily_costs" do
    field(:total_cents_ars, :integer)
    field(:date, :date)

    belongs_to(:recipe, MealPlannerApi.Persistence.Catalog.Recipe)
    belongs_to(:supermarket, MealPlannerApi.Persistence.Shopping.Supermarket)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(cost, attrs) do
    cost
    |> cast(attrs, [:recipe_id, :supermarket_id, :total_cents_ars, :date])
    |> validate_required([:recipe_id, :supermarket_id, :total_cents_ars, :date])
    |> validate_number(:total_cents_ars, greater_than_or_equal_to: 0)
    |> unique_constraint([:recipe_id, :supermarket_id, :date])
    |> foreign_key_constraint(:recipe_id)
    |> foreign_key_constraint(:supermarket_id)
  end
end
