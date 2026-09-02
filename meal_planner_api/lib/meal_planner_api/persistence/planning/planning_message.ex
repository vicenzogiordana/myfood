defmodule MealPlannerApi.Persistence.Planning.PlanningMessage do
  @moduledoc """
  Chat row scoped to a `PlanningSession`. Hard-deleted on terminal
  transitions (cancel / expire / lost_lock) per design.md; the
  `:committed` path keeps messages alongside the audit row until a
  future TTL/prune step (deferred — see design.md §"Open Questions").

  `intent_kind` is intentionally a free-form string column: the
  `:role = :assistant` rows carry the validated typed-intent name, while
  `:role = :user | :system` rows leave it NULL. The closed set of
  intent kinds is enforced at the boundary by
  `GenerationService.validate_ai_intent/1` (PR2).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "planning_messages" do
    field(:role, Ecto.Enum, values: [:user, :assistant, :system])
    field(:content, :string)
    field(:intent_kind, :string)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:session, MealPlannerApi.Persistence.Planning.PlanningSession)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:account_id, :session_id, :role, :content, :intent_kind])
    |> validate_required([:account_id, :session_id, :role, :content])
    |> validate_inclusion(:role, [:user, :assistant, :system])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:session_id)
  end
end
