defmodule MealPlannerApi.Persistence.Inventory.InventoryMutationEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "inventory_mutation_events" do
    field(:trigger_type, Ecto.Enum, values: [:purchase, :cooking, :manual, :voice])
    field(:operation, Ecto.Enum, values: [:add, :subtract, :set, :delete])
    field(:quantity_before_milli, :integer)
    field(:quantity_delta_milli, :integer)
    field(:quantity_after_milli, :integer)
    field(:raw_voice_text, :string)
    field(:metadata, :map)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:inventory_item, MealPlannerApi.Persistence.Inventory.InventoryItem)

    belongs_to(:source_checkout_session, MealPlannerApi.Persistence.Shopping.CheckoutSession,
      foreign_key: :source_checkout_session_id
    )

    belongs_to(:source_cooking_session, MealPlannerApi.Persistence.Planning.CookingSession,
      foreign_key: :source_cooking_session_id
    )

    belongs_to(:source_user, MealPlannerApi.Persistence.Accounts.User,
      foreign_key: :source_user_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :account_id,
      :inventory_item_id,
      :trigger_type,
      :operation,
      :quantity_before_milli,
      :quantity_delta_milli,
      :quantity_after_milli,
      :source_checkout_session_id,
      :source_cooking_session_id,
      :source_user_id,
      :raw_voice_text,
      :metadata
    ])
    |> validate_required([
      :account_id,
      :inventory_item_id,
      :trigger_type,
      :operation,
      :quantity_before_milli,
      :quantity_delta_milli,
      :quantity_after_milli,
      :source_user_id
    ])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:inventory_item_id)
    |> foreign_key_constraint(:source_checkout_session_id)
    |> foreign_key_constraint(:source_cooking_session_id)
    |> foreign_key_constraint(:source_user_id)
  end
end
