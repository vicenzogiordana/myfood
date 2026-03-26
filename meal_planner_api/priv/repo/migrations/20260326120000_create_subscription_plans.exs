defmodule MealPlannerApi.Repo.Migrations.CreateSubscriptionPlans do
  use Ecto.Migration

  def change do
    create table(:subscription_plans, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:max_users, :integer, null: false)
      add(:max_planning_days, :integer, null: false)
      add(:revenuecat_entitlement_id, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:subscription_plans, [:name]))

    alter table(:accounts) do
      add(
        :subscription_plan_id,
        references(:subscription_plans, type: :binary_id, on_delete: :restrict)
      )
    end

    create(index(:accounts, [:subscription_plan_id]))
  end
end
