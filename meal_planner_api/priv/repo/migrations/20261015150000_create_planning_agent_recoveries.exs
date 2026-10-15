defmodule MealPlannerApi.Repo.Migrations.CreatePlanningAgentRecoveries do
  use Ecto.Migration

  @moduledoc """
  Recoverable storage of agent Planning Sessions (spec #93, issue #107): one
  snapshot per active session (transcript, Workspace, limits and the model
  adapter's recoverable spend, never credentials), so a server restart
  within the absence grace restores the session when its Member returns.
  The row is deleted whenever the Planning Session ends.
  """

  def change do
    create table(:planning_agent_recoveries, primary_key: false) do
      add(
        :session_id,
        references(:planning_sessions, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:snapshot, :binary, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:planning_agent_recoveries, [:account_id])
  end
end
