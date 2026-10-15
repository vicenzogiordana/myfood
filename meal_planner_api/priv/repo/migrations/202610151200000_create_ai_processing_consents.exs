defmodule MealPlannerApi.Repo.Migrations.CreateAiProcessingConsents do
  use Ecto.Migration

  @moduledoc """
  Explicit consent of a Member before their Household data is first sent to an
  external AI provider (spec #93, user story 5). One row per (Household, User).
  """

  def change do
    create table(:ai_processing_consents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:granted_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ai_processing_consents, [:account_id, :user_id])
  end
end
