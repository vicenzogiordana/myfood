defmodule MealPlannerApi.Repo.Migrations.AddAgentToPlanningSessions do
  use Ecto.Migration

  @moduledoc """
  Marks the rows owned by an agent Planning Session (spec #93, issue #119),
  so the legacy session path can refuse to start while an agent session
  holds the Household. Existing rows are legacy rows.
  """

  def change do
    alter table(:planning_sessions) do
      add(:agent, :boolean, null: false, default: false)
    end
  end
end
