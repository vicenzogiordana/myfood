defmodule MealPlannerApi.Repo.Migrations.AddCheckoutSessionToShoppingItems do
  use Ecto.Migration

  def change do
    alter table(:shopping_items) do
      add(
        :checkout_session_id,
        references(:checkout_sessions, type: :binary_id, on_delete: :nilify_all),
        null: true
      )
    end

    create(index(:shopping_items, [:checkout_session_id]))
  end
end
