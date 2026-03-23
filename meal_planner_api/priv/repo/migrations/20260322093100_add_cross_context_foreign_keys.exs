defmodule MealPlannerApi.Repo.Migrations.AddCrossContextForeignKeys do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      modify :preferred_supermarket_id,
             references(:supermarkets, type: :binary_id, on_delete: :nilify_all),
             from: :binary_id
    end

    create index(:accounts, [:preferred_supermarket_id])

    alter table(:recipe_daily_costs) do
      modify :supermarket_id,
             references(:supermarkets, type: :binary_id, on_delete: :restrict),
             from: :binary_id
    end
  end
end
