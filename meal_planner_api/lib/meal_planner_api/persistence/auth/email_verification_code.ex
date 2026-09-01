defmodule MealPlannerApi.Persistence.Auth.EmailVerificationCode do
  @moduledoc """
  Phase 1 — Persistence and Code Request (issue #31).

  One row per pending (or recently-consumed) email verification code.
  Codes are never stored in plaintext — only their SHA-256 hex digest.

  See `specs/email-code-authentication/spec.md` requirement "Code
  Request and Non-Enumerating Storage" and `design.md` §"Persistence
  Shapes".
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "email_verification_codes" do
    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)
    field(:email, :string)
    field(:code_hash, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end
end
