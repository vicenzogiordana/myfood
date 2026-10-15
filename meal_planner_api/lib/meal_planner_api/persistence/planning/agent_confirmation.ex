defmodule MealPlannerApi.Persistence.Planning.AgentConfirmation do
  @moduledoc """
  A Member's confirmation of an agent Proposal. Its id is the confirmation
  identity: the id of the confirmed Proposal.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "planning_agent_confirmations" do
    field(:range_from, :date)
    field(:range_to, :date)
    field(:meals_count, :integer)
    field(:shopping_lines_count, :integer)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:planning_session, MealPlannerApi.Persistence.Planning.PlanningSession)

    belongs_to(:confirmed_by_membership, MealPlannerApi.Persistence.Accounts.AccountMembership,
      foreign_key: :confirmed_by_membership_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(id account_id planning_session_id confirmed_by_membership_id range_from range_to
             meals_count shopping_lines_count)a

  def changeset(confirmation, attrs) do
    confirmation
    |> cast(attrs, @fields)
    |> validate_required(@fields -- [:planning_session_id, :confirmed_by_membership_id])
    |> unique_constraint(:id, name: :planning_agent_confirmations_pkey)
    |> foreign_key_constraint(:account_id)
  end
end
