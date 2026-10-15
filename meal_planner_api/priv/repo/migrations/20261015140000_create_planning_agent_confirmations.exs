defmodule MealPlannerApi.Repo.Migrations.CreatePlanningAgentConfirmations do
  use Ecto.Migration

  @moduledoc """
  Confirmations of agent Proposals (spec #93, issue #102). The primary key is
  the confirmation identity, the confirmed Proposal's id: a replayed
  confirmation finds its row instead of saving twice. Rows outlive the
  Planning Session and its Workspace so a lost acknowledgement can be
  reconciled and the status queried later.
  """

  def change do
    create table(:planning_agent_confirmations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :planning_session_id,
        references(:planning_sessions, type: :binary_id, on_delete: :nilify_all)
      )

      add(
        :confirmed_by_membership_id,
        references(:account_memberships, type: :binary_id, on_delete: :nilify_all)
      )

      add(:range_from, :date, null: false)
      add(:range_to, :date, null: false)
      add(:meals_count, :integer, null: false)
      add(:shopping_lines_count, :integer, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:planning_agent_confirmations, [:account_id])
  end
end
