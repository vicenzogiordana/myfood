defmodule MealPlannerApi.Repo.Migrations.AddDinersToScheduledMeals do
  @moduledoc """
  Planned Meals record who eats them (issue #152): `diners` (Members present
  plus guests; null for meals planned before) and `guests`. The batches of
  the recipe stay in `selected_quantity`.
  """

  use Ecto.Migration

  def change do
    alter table(:scheduled_meals) do
      add(:diners, :integer)
      add(:guests, :integer, null: false, default: 0)
    end

    create(constraint(:scheduled_meals, :non_negative_diners, check: "diners >= 0"))
    create(constraint(:scheduled_meals, :non_negative_guests, check: "guests >= 0"))
  end
end
