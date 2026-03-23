defmodule MealPlannerApi.Persistence.Planning.CookingChatMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cooking_chat_messages" do
    field(:role, Ecto.Enum, values: [:user, :assistant, :system])
    field(:content, :string)

    belongs_to(:cooking_session, MealPlannerApi.Persistence.Planning.CookingSession)
    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:cooking_session_id, :user_id, :role, :content])
    |> validate_required([:cooking_session_id, :role, :content])
    |> foreign_key_constraint(:cooking_session_id)
    |> foreign_key_constraint(:user_id)
  end
end
