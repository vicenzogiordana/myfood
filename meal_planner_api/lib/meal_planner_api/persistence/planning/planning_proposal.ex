defmodule MealPlannerApi.Persistence.Planning.PlanningProposal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "planning_proposals" do
    field(:proposal_json, :map)
    field(:status, Ecto.Enum, values: [:pending, :accepted, :rejected], default: :pending)

    belongs_to(:generation_run, MealPlannerApi.Persistence.Planning.PlanningGenerationRun,
      foreign_key: :generation_run_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [:generation_run_id, :proposal_json, :status])
    |> validate_required([:generation_run_id, :proposal_json, :status])
    |> foreign_key_constraint(:generation_run_id)
  end
end
