defmodule MealPlannerApi.Persistence.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "accounts" do
    field(:name, :string)
    field(:account_type, Ecto.Enum, values: [:individual, :group])
    field(:default_budget_cents, :integer, default: 0)

    belongs_to(:subscription_plan, MealPlannerApi.Subscriptions.Plan,
      foreign_key: :subscription_plan_id
    )

    belongs_to(:preferred_supermarket, MealPlannerApi.Persistence.Shopping.Supermarket,
      foreign_key: :preferred_supermarket_id
    )

    has_many(:users, MealPlannerApi.Persistence.Accounts.User)
    has_many(:revenuecat_customers, MealPlannerApi.Persistence.Accounts.RevenuecatCustomer)
    has_many(:revenuecat_entitlements, MealPlannerApi.Persistence.Accounts.RevenuecatEntitlement)

    has_many(
      :revenuecat_webhook_events,
      MealPlannerApi.Persistence.Accounts.RevenuecatWebhookEvent
    )

    has_many(
      :revenuecat_subscription_snapshots,
      MealPlannerApi.Persistence.Accounts.RevenuecatSubscriptionSnapshot
    )

    has_many(:shopping_items, MealPlannerApi.Persistence.Shopping.ShoppingItem)
    has_many(:checkout_sessions, MealPlannerApi.Persistence.Shopping.CheckoutSession)
    has_many(:inventory_items, MealPlannerApi.Persistence.Inventory.InventoryItem)

    has_many(
      :inventory_mutation_events,
      MealPlannerApi.Persistence.Inventory.InventoryMutationEvent
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :name,
      :account_type,
      :default_budget_cents,
      :preferred_supermarket_id,
      :subscription_plan_id
    ])
    |> validate_required([:name, :account_type, :default_budget_cents])
    |> validate_number(:default_budget_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:preferred_supermarket_id)
    |> foreign_key_constraint(:subscription_plan_id)
  end
end
