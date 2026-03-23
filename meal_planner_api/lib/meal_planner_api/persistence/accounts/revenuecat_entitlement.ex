defmodule MealPlannerApi.Persistence.Accounts.RevenuecatEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "revenuecat_entitlements" do
    field(:rc_app_user_id, :string)
    field(:entitlement_id, :string)
    field(:product_identifier, :string)
    field(:is_active, :boolean)
    field(:will_renew, :boolean)
    field(:store, :string)
    field(:purchase_date, :utc_datetime_usec)
    field(:expiration_date, :utc_datetime_usec)
    field(:grace_period_expires_date, :utc_datetime_usec)
    field(:raw_payload, :map)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :account_id,
      :rc_app_user_id,
      :entitlement_id,
      :product_identifier,
      :is_active,
      :will_renew,
      :store,
      :purchase_date,
      :expiration_date,
      :grace_period_expires_date,
      :raw_payload
    ])
    |> validate_required([
      :account_id,
      :rc_app_user_id,
      :entitlement_id,
      :is_active,
      :raw_payload
    ])
    |> unique_constraint([:account_id, :entitlement_id])
    |> foreign_key_constraint(:account_id)
  end
end
