defmodule MealPlannerApi.Persistence.Catalog.SlotFavorite do
  @moduledoc """
  Marks a specific planned slot (date + slot + recipe) as favorite.
  Separate from FavoriteRecipe — this is instance-level (this Tuesday's lunch),
  not recipe-level (that pasta dish).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "slot_favorites" do
    field(:date, :date)
    field(:slot, :string)

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account, type: :binary_id)
    belongs_to(:user, MealPlannerApi.Persistence.Accounts.User, type: :binary_id)

    belongs_to(:scheduled_meal, MealPlannerApi.Persistence.Planning.ScheduledMeal,
      type: :binary_id
    )

    belongs_to(:recipe, MealPlannerApi.Persistence.Catalog.Recipe, type: :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @slot_values ~w(breakfast lunch snack dinner)a

  def slot_values, do: @slot_values

  def changeset(slot_favorite, attrs) do
    slot_favorite
    |> Ecto.Changeset.cast(attrs, [
      :account_id,
      :user_id,
      :date,
      :slot,
      :scheduled_meal_id,
      :recipe_id
    ])
    |> Ecto.Changeset.validate_required([
      :account_id,
      :user_id,
      :date,
      :slot,
      :scheduled_meal_id,
      :recipe_id
    ])
    |> Ecto.Changeset.validate_inclusion(:slot, @slot_values)
    |> Ecto.Changeset.unique_constraint(
      [:account_id, :user_id, :date, :slot],
      name: :slot_favorites_account_id_user_id_date_slot_index
    )
  end
end
