defmodule MealPlannerApi.Repo.Migrations.AddPendingDeliveryStatuses do
  use Ecto.Migration

  def up do
    drop constraint(:checkout_sessions, :checkout_sessions_status_check)

    create constraint(:checkout_sessions, :checkout_sessions_status_check,
             check: "status IN ('draft', 'processing', 'pending_delivery', 'completed', 'abandoned')"
           )

    drop constraint(:shopping_items, :shopping_items_status_check)

    create constraint(:shopping_items, :shopping_items_status_check,
             check: "status IN ('pending', 'in_cart', 'pending_delivery', 'checked_out', 'archived')"
           )
  end

  def down do
    drop constraint(:checkout_sessions, :checkout_sessions_status_check)

    create constraint(:checkout_sessions, :checkout_sessions_status_check,
             check: "status IN ('draft', 'processing', 'completed', 'abandoned')"
           )

    drop constraint(:shopping_items, :shopping_items_status_check)

    create constraint(:shopping_items, :shopping_items_status_check,
             check: "status IN ('pending', 'in_cart', 'checked_out', 'archived')"
           )
  end
end
