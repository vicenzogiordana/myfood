defmodule MealPlannerApi.Persistence.Planning.CookingSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cooking_sessions" do
    field(:status, Ecto.Enum, values: [:active, :paused, :completed], default: :active)
    field(:context_snapshot, :map)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:scheduled_meal, MealPlannerApi.Persistence.Planning.ScheduledMeal)

    has_many(:chat_messages, MealPlannerApi.Persistence.Planning.CookingChatMessage)
    has_many(:step_events, MealPlannerApi.Persistence.Planning.CookingStepEvent)
    has_many(:context_snapshots, MealPlannerApi.Persistence.Planning.ContextSnapshot)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :account_id,
      :scheduled_meal_id,
      :status,
      :context_snapshot,
      :started_at,
      :completed_at
    ])
    |> validate_required([:account_id, :scheduled_meal_id, :status])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:scheduled_meal_id)
  end
end
