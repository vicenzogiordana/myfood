defmodule MealPlannerApi.Persistence.Accounts.RevenuecatCustomer do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "revenuecat_customers" do
    field(:rc_app_user_id, :string)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(customer, attrs) do
    customer
    |> cast(attrs, [:account_id, :user_id, :rc_app_user_id])
    |> validate_required([:account_id, :rc_app_user_id])
    |> unique_constraint(:rc_app_user_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
  end
end
