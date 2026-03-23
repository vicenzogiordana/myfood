defmodule MealPlannerApi.Repo.Migrations.CreatePlanningAndCookingTables do
  use Ecto.Migration

  def change do
    create table(:planning_generation_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :status, :string, null: false, default: "pending"
      add :input_context, :map, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:planning_generation_runs, [:account_id])
    create index(:planning_generation_runs, [:user_id])
    create index(:planning_generation_runs, [:status])
    create index(:planning_generation_runs, [:inserted_at])

    create constraint(:planning_generation_runs, :planning_generation_runs_status_check,
             check: "status IN ('pending', 'processing', 'completed', 'error')"
           )

    create table(:planning_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :generation_run_id,
          references(:planning_generation_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :proposal_json, :map, null: false
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:planning_proposals, [:generation_run_id])
    create index(:planning_proposals, [:status])

    create constraint(:planning_proposals, :planning_proposals_status_check,
             check: "status IN ('pending', 'accepted', 'rejected')"
           )

    create table(:scheduled_meals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :date, :date, null: false
      add :slot, :string, null: false

      add :recipe_id,
          references(:recipes, type: :binary_id, on_delete: :nilify_all)

      add :is_cooked, :boolean, null: false, default: false

      add :ai_generation_id,
          references(:planning_generation_runs, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scheduled_meals, [:account_id])
    create index(:scheduled_meals, [:date])
    create index(:scheduled_meals, [:recipe_id])
    create index(:scheduled_meals, [:ai_generation_id])
    create unique_index(:scheduled_meals, [:account_id, :date, :slot])

    create constraint(:scheduled_meals, :scheduled_meals_slot_check,
             check: "slot IN ('breakfast', 'lunch', 'snack', 'dinner')"
           )

    create table(:cooking_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :scheduled_meal_id,
          references(:scheduled_meals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :status, :string, null: false, default: "active"
      add :context_snapshot, :map
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cooking_sessions, [:account_id])
    create index(:cooking_sessions, [:scheduled_meal_id])
    create index(:cooking_sessions, [:status])

    create constraint(:cooking_sessions, :cooking_sessions_status_check,
             check: "status IN ('active', 'paused', 'completed')"
           )

    create table(:cooking_chat_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :cooking_session_id,
          references(:cooking_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :role, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cooking_chat_messages, [:cooking_session_id])
    create index(:cooking_chat_messages, [:user_id])
    create index(:cooking_chat_messages, [:inserted_at])

    create constraint(:cooking_chat_messages, :cooking_chat_messages_role_check,
             check: "role IN ('user', 'assistant', 'system')"
           )

    create table(:cooking_step_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :cooking_session_id,
          references(:cooking_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :recipe_step_id,
          references(:recipe_steps, type: :binary_id, on_delete: :restrict),
          null: false

      add :event_type, :string, null: false
      add :event_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cooking_step_events, [:cooking_session_id])
    create index(:cooking_step_events, [:recipe_step_id])
    create index(:cooking_step_events, [:event_at])

    create constraint(:cooking_step_events, :cooking_step_events_event_type_check,
             check: "event_type IN ('started', 'paused', 'completed', 'error')"
           )

    create table(:context_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :cooking_session_id,
          references(:cooking_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :snapshot_data, :map, null: false
      add :captured_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:context_snapshots, [:cooking_session_id])
    create index(:context_snapshots, [:captured_at])
  end
end
