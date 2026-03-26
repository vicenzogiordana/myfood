defmodule MealPlannerApi.Subscriptions.Plan do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "subscription_plans" do
    field(:name, :string)
    field(:max_users, :integer)
    field(:max_planning_days, :integer)
    field(:revenuecat_entitlement_id, :string)

    has_many(:accounts, MealPlannerApi.Persistence.Accounts.Account,
      foreign_key: :subscription_plan_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:name, :max_users, :max_planning_days, :revenuecat_entitlement_id])
    |> validate_required([:name, :max_users, :max_planning_days])
    |> validate_number(:max_users, greater_than: 0)
    |> validate_number(:max_planning_days, greater_than: 0)
    |> unique_constraint(:name)
  end
end
