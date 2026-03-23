defmodule MealPlannerApi.Persistence.Shopping.ShoppingItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "shopping_items" do
    field(:planned_date, :date)
    field(:quantity_milli, :integer)
    field(:unit, Ecto.Enum, values: [:g, :ml, :unit])

    field(:status, Ecto.Enum,
      values: [:pending, :in_cart, :pending_delivery, :checked_out, :archived],
      default: :pending
    )

    field(:estimated_price_cents, :integer)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:scheduled_meal, MealPlannerApi.Persistence.Planning.ScheduledMeal)
    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    belongs_to(:assigned_supermarket, MealPlannerApi.Persistence.Shopping.Supermarket,
      foreign_key: :assigned_supermarket_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :account_id,
      :scheduled_meal_id,
      :planned_date,
      :ingredient_id,
      :quantity_milli,
      :unit,
      :assigned_supermarket_id,
      :status,
      :estimated_price_cents
    ])
    |> validate_required([
      :account_id,
      :scheduled_meal_id,
      :planned_date,
      :ingredient_id,
      :quantity_milli,
      :unit,
      :status
    ])
    |> validate_number(:quantity_milli, greater_than: 0)
    |> validate_number(:estimated_price_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:scheduled_meal_id)
    |> foreign_key_constraint(:ingredient_id)
    |> foreign_key_constraint(:assigned_supermarket_id)
  end
end
