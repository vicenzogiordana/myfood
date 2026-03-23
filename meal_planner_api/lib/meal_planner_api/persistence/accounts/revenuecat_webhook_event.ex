defmodule MealPlannerApi.Persistence.Accounts.RevenuecatWebhookEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "revenuecat_webhook_events" do
    field(:event_id, :string)
    field(:event_type, :string)
    field(:rc_app_user_id, :string)

    field(:status, Ecto.Enum,
      values: [:received, :processed, :failed, :ignored],
      default: :received
    )

    field(:received_at, :utc_datetime_usec)
    field(:processed_at, :utc_datetime_usec)
    field(:error_message, :string)
    field(:payload, :map)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :event_type,
      :rc_app_user_id,
      :account_id,
      :status,
      :received_at,
      :processed_at,
      :error_message,
      :payload
    ])
    |> validate_required([
      :event_id,
      :event_type,
      :rc_app_user_id,
      :status,
      :received_at,
      :payload
    ])
    |> unique_constraint(:event_id)
    |> foreign_key_constraint(:account_id)
  end
end
