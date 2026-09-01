defmodule MealPlannerApi.Persistence.Auth.AccountSelectionContinuationMembership do
  @moduledoc """
  Phase 3 — Outcomes and Continuations (issue #31 task 3.4).

  Join row binding a continuation to one of its allowed
  `AccountMembership` ids. The exchange transaction verifies that the
  supplied `membership_id` resolves to one of these join rows for the
  requested continuation before delegating to
  `MealPlannerApi.AccountsMembership.switch_account/2`.

  Composite primary key `(continuation_id, membership_id)` enforces the
  uniqueness invariant in the database; an FK `on_delete: :delete_all`
  from both parents means dropping a continuation (or a membership)
  cascades to its links.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "account_selection_continuation_memberships" do
    belongs_to(
      :continuation,
      MealPlannerApi.Persistence.Auth.AccountSelectionContinuation,
      primary_key: true,
      foreign_key: :continuation_id
    )

    belongs_to(:membership, MealPlannerApi.Persistence.Accounts.AccountMembership,
      primary_key: true,
      foreign_key: :membership_id
    )
  end

  @doc """
  Casts and validates a join changeset. Both FKs are required.
  """
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:continuation_id, :membership_id])
    |> validate_required([:continuation_id, :membership_id])
    |> foreign_key_constraint(:continuation_id)
    |> foreign_key_constraint(:membership_id)
  end
end
