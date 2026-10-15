defmodule MealPlannerApi.Persistence.Planning.PlanningAgentRecovery do
  @moduledoc """
  The recoverable snapshot of one active agent Planning Session (spec #93,
  issue #107). `snapshot` is an opaque binary owned by
  `MealPlannerApi.PlanningAgent.Session`; it never holds credentials. The
  row lives only while its Planning Session is active.
  """

  use Ecto.Schema

  @primary_key {:session_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "planning_agent_recoveries" do
    field(:account_id, :binary_id)
    field(:snapshot, :binary)

    timestamps(type: :utc_datetime_usec)
  end
end
