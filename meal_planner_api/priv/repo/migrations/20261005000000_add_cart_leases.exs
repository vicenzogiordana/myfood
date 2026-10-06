defmodule MealPlannerApi.Repo.Migrations.AddCartLeases do
  use Ecto.Migration

  def change do
    alter table(:checkout_sessions) do
      add(:reserved_by_user_id, references(:users, type: :binary_id))
      add(:lease_expires_at, :utc_datetime_usec)
      add(:purchase_result, :map)
    end

    alter table(:shopping_items) do
      add(:reservation_token, :uuid)
    end

    create(
      index(:checkout_sessions, [:lease_expires_at],
        where: "status = 'draft' AND reserved_by_user_id IS NOT NULL",
        name: :cart_expiry_lookup
      )
    )

    create(
      unique_index(:checkout_sessions, [:account_id, :reserved_by_user_id],
        where: "status = 'draft' AND reserved_by_user_id IS NOT NULL",
        name: :one_active_member_cart
      )
    )
  end
end
