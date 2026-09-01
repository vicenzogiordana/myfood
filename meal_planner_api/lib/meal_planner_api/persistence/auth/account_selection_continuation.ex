defmodule MealPlannerApi.Persistence.Auth.AccountSelectionContinuation do
  @moduledoc """
  Phase 3 — Outcomes and Continuations (issue #31 task 3.4).

  Single-use, five-minute opaque token returned by the email-code verify
  multi-membership outcome. The plaintext is 32 random bytes base64url-
  encoded (no padding) and is never persisted — only its SHA-256 hex
  digest (column `token_hash`) is stored. The row is bound to a single
  `user_id` and to a membership set on
  `MealPlannerApi.Persistence.Auth.AccountSelectionContinuationMembership`.

  Single-use is enforced by `consumed_at` being non-`nil` after a
  successful exchange. The `Repo.transaction/1` wrapping the lookup +
  `switch_account/2` delegation + JWT minting + `consumed_at` update
  guarantees that either every step commits together or none of them
  do (`design.md` §"Interfaces / Contracts": "Minting and consumption
  commit together, so concurrent/replayed exchange has one success;
  pre-mint failures do not consume.").
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "account_selection_continuations" do
    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)

    field(:token_hash, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)

    has_many(
      :membership_links,
      MealPlannerApi.Persistence.Auth.AccountSelectionContinuationMembership,
      foreign_key: :continuation_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts and validates a continuation changeset. Required: `user_id`,
  `token_hash`, `expires_at`. `consumed_at` is set by the exchange
  transaction, not by callers.
  """
  def changeset(continuation, attrs) do
    continuation
    |> cast(attrs, [:user_id, :token_hash, :expires_at, :consumed_at])
    |> validate_required([:user_id, :token_hash, :expires_at])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash,
      name: :account_selection_continuations_token_hash_unique_index
    )
  end
end
