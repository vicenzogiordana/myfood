defmodule MealPlannerApi.Persistence.Planning.PlanningException do
  @moduledoc """
  Exception row scoped to a `PlanningSession`. Free-form string `kind`
  (no enum — the surface area is "anything worth logging" and the AI
  boundary does not own it; `:forbidden_intent`, validation errors,
  optimizer failures, etc. all flow through here).

  Hard-deleted on terminal transitions (cancel / expire / lost_lock)
  alongside `PlanningMessage` rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "planning_exceptions" do
    field(:kind, :string)
    field(:note, :string)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:session, MealPlannerApi.Persistence.Planning.PlanningSession)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(exception, attrs) do
    exception
    |> cast(attrs, [:account_id, :session_id, :kind, :note])
    |> validate_required([:account_id, :session_id, :kind])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:session_id)
  end
end
