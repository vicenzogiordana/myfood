defmodule MealPlannerApi.Persistence.Planning.AiProcessingConsent do
  @moduledoc """
  A Member's explicit consent to external AI processing within one Household.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ai_processing_consents" do
    field(:granted_at, :utc_datetime_usec)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(consent, attrs) do
    consent
    |> cast(attrs, [:account_id, :user_id, :granted_at])
    |> validate_required([:account_id, :user_id, :granted_at])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:account_id, :user_id])
  end
end
