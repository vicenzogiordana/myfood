defmodule MealPlannerApiWeb.AccountsController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Budgets
  alias MealPlannerApi.Inventory
  alias MealPlannerApi.Subscriptions

  def me(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    json(conn, %{
      user: Accounts.serialize_user(user),
      claims: Guardian.Plug.current_claims(conn)
    })
  end

  def context(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    budget = Budgets.resolve_for(user, params)
    inventory = Inventory.available_for(user, params)
    subscription = Subscriptions.policy_for_account(user.account_id)

    json(conn, %{
      account_id: user.account_id,
      budget: Budgets.serialize(budget),
      inventory_items: Inventory.names(inventory),
      subscription: subscription
    })
  end
end
