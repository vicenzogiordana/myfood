defmodule MealPlannerApi.Persistence.Inventory.InventoryItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "inventory_items" do
    field(:quantity_milli, :integer)
    field(:unit, Ecto.Enum, values: [:g, :ml, :unit])
    field(:source_kind, Ecto.Enum, values: [:planned, :extra])
    field(:acquired_price_cents, :integer)
    field(:acquired_at, :utc_datetime_usec)
    field(:expired_at, :utc_datetime_usec)
    field(:last_mutation_at, :utc_datetime_usec)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    has_many(:mutation_events, MealPlannerApi.Persistence.Inventory.InventoryMutationEvent)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :account_id,
      :ingredient_id,
      :quantity_milli,
      :unit,
      :source_kind,
      :acquired_price_cents,
      :acquired_at,
      :expired_at,
      :last_mutation_at
    ])
    |> validate_required([
      :account_id,
      :ingredient_id,
      :quantity_milli,
      :unit,
      :source_kind,
      :last_mutation_at
    ])
    |> validate_number(:quantity_milli, greater_than_or_equal_to: 0)
    |> validate_number(:acquired_price_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:ingredient_id)
  end
end
