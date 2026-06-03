defmodule MealPlannerApi.Persistence.Planning.PlanningGenerationRun do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "planning_generation_runs" do
    field(:status, Ecto.Enum,
      values: [:pending, :processing, :completed, :error],
      default: :pending
    )

    field(:input_context, :map)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)

    has_many(:proposals, MealPlannerApi.Persistence.Planning.PlanningProposal,
      foreign_key: :generation_run_id
    )

    has_many(:scheduled_meals, MealPlannerApi.Persistence.Planning.ScheduledMeal,
      foreign_key: :ai_generation_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:account_id, :user_id, :status, :input_context, :started_at, :completed_at])
    |> validate_required([:account_id, :user_id, :status])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
  end
end
