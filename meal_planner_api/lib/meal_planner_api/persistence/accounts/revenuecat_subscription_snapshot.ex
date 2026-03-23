defmodule MealPlannerApi.Persistence.Accounts.RevenuecatSubscriptionSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "revenuecat_subscription_snapshots" do
    field(:rc_app_user_id, :string)
    field(:product_identifier, :string)
    field(:entitlement_id, :string)
    field(:status, :string)
    field(:period_type, :string)
    field(:purchase_date, :utc_datetime_usec)
    field(:expiration_date, :utc_datetime_usec)
    field(:store, :string)
    field(:event_id, :string)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :account_id,
      :rc_app_user_id,
      :product_identifier,
      :entitlement_id,
      :status,
      :period_type,
      :purchase_date,
      :expiration_date,
      :store,
      :event_id
    ])
    |> validate_required([:account_id, :rc_app_user_id, :product_identifier, :status])
    |> foreign_key_constraint(:account_id)
  end
end
