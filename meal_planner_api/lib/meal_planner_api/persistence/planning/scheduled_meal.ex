defmodule MealPlannerApi.Persistence.Planning.ScheduledMeal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "scheduled_meals" do
    field(:date, :date)
    field(:slot, Ecto.Enum, values: [:breakfast, :lunch, :snack, :dinner])
    field(:is_cooked, :boolean, default: false)
    field(:recipe_version_id, :binary_id, read_after_writes: true)
    field(:recipe_snapshot, :map, read_after_writes: true)
    field(:selected_quantity, :integer, default: 1)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:recipe, MealPlannerApi.Persistence.Catalog.Recipe)

    belongs_to(:ai_generation_run, MealPlannerApi.Persistence.Planning.PlanningGenerationRun,
      foreign_key: :ai_generation_id
    )

    has_many(:cooking_sessions, MealPlannerApi.Persistence.Planning.CookingSession)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(scheduled_meal, attrs) do
    scheduled_meal
    |> cast(attrs, [
      :account_id,
      :date,
      :slot,
      :recipe_id,
      :is_cooked,
      :ai_generation_id,
      :selected_quantity
    ])
    |> validate_number(:selected_quantity, greater_than: 0)
    |> validate_required([:account_id, :date, :slot])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:recipe_id)
    |> foreign_key_constraint(:ai_generation_id)
    |> unique_constraint([:account_id, :date, :slot])
  end
end
