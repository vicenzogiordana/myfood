defmodule MealPlannerApi.Persistence.Accounts.AccountMembership do
  @moduledoc """
  Join entity between `User` and `Account`. Created in Phase A — Tenancy Refactor.

  See `specs/account-membership.md` and `design.md` §2.1.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "account_memberships" do
    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)

    belongs_to(:invited_by, MealPlannerApi.Persistence.Accounts.User,
      foreign_key: :invited_by_user_id
    )

    field(:role, Ecto.Enum, values: [:owner, :member])
    field(:status, Ecto.Enum, values: [:active, :invited, :suspended])
    field(:invite_token_hash, :string)
    field(:invite_expires_at, :utc_datetime_usec)
    field(:joined_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts and validates a membership changeset. Required fields: account_id,
  user_id, role, status.
  """
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :account_id,
      :user_id,
      :role,
      :status,
      :invited_by_user_id,
      :invite_token_hash,
      :invite_expires_at,
      :joined_at
    ])
    |> validate_required([:account_id, :user_id, :role, :status])
    |> validate_inclusion(:role, [:owner, :member])
    |> validate_inclusion(:status, [:active, :invited, :suspended])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:invited_by_user_id)
    |> unique_constraint([:account_id, :user_id],
      name: :account_memberships_active_account_user_unique_index
    )
  end
end
