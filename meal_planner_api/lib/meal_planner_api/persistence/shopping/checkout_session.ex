defmodule MealPlannerApi.Persistence.Shopping.CheckoutSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "checkout_sessions" do
    field(:status, Ecto.Enum,
      values: [:draft, :processing, :pending_delivery, :completed, :abandoned],
      default: :draft
    )

    field(:checkout_type, Ecto.Enum, values: [:physical, :online])
    field(:grouping_by_supermarket, :map)
    field(:total_cents, :integer)
    field(:confirmed_at, :utc_datetime_usec)
    field(:invalidated_at, :utc_datetime_usec)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:confirmed_by_user, MealPlannerApi.Persistence.Accounts.User)

    has_many(
      :inventory_mutation_events,
      MealPlannerApi.Persistence.Inventory.InventoryMutationEvent,
      foreign_key: :source_checkout_session_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :account_id,
      :status,
      :checkout_type,
      :grouping_by_supermarket,
      :total_cents,
      :confirmed_by_user_id,
      :confirmed_at,
      :invalidated_at
    ])
    |> validate_required([:account_id, :status, :checkout_type])
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:confirmed_by_user_id)
  end
end
