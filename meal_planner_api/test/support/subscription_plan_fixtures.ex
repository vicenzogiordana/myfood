defmodule MealPlannerApi.SubscriptionPlanFixtures do
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions.Plan

  @plans [
    %{name: "individual", max_users: 1, max_planning_days: 7, revenuecat_entitlement_id: nil},
    %{name: "family_4", max_users: 4, max_planning_days: 7, revenuecat_entitlement_id: nil},
    %{name: "family_6", max_users: 6, max_planning_days: 7, revenuecat_entitlement_id: nil}
  ]

  def ensure_plans! do
    Enum.each(@plans, fn attrs ->
      %Plan{}
      |> Plan.changeset(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace, [:max_users, :max_planning_days, :revenuecat_entitlement_id, :updated_at]},
        conflict_target: [:name]
      )
    end)

    :ok
  end
end
