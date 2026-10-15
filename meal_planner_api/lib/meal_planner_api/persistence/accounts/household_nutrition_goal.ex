defmodule MealPlannerApi.Persistence.Accounts.HouseholdNutritionGoal do
  @moduledoc """
  A Household's Nutrition Goal: one daily range of calories and macros
  (protein, carbs, fat) per standard portion, kept in household settings.

  One row per Household (`accounts.id`). Every bound is a non-negative
  integer (kcal for calories, grams for macros) and each range must satisfy
  `min <= max`. A Member's private macro focus is a Preference stored on the
  dietary profile, never here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @ranges [:calories, :protein_g, :carbs_g, :fat_g]
  @bound_fields Enum.flat_map(@ranges, &[:"#{&1}_min", :"#{&1}_max"])

  schema "household_nutrition_goals" do
    for field_name <- @bound_fields do
      field(field_name, :integer)
    end

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The range keys of a Nutrition Goal, in display order."
  @spec ranges() :: [atom()]
  def ranges, do: @ranges

  @doc """
  Casts and validates the full set of ranges. All eight bounds are required:
  an update replaces the whole goal.
  """
  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [:account_id | @bound_fields])
    |> validate_required([:account_id | @bound_fields])
    |> validate_bounds()
    |> unique_constraint(:account_id)
    |> foreign_key_constraint(:account_id)
  end

  defp validate_bounds(changeset) do
    Enum.reduce(@ranges, changeset, fn range, acc ->
      min_field = :"#{range}_min"
      max_field = :"#{range}_max"

      acc
      |> validate_number(min_field, greater_than_or_equal_to: 0)
      |> validate_number(max_field, greater_than_or_equal_to: 0)
      |> validate_min_not_above_max(min_field, max_field)
      |> check_constraint(min_field, name: :"#{range}_range_valid")
    end)
  end

  defp validate_min_not_above_max(changeset, min_field, max_field) do
    min_value = get_field(changeset, min_field)
    max_value = get_field(changeset, max_field)

    if is_integer(min_value) and is_integer(max_value) and min_value > max_value do
      add_error(changeset, min_field, "must be less than or equal to %{max}",
        max: max_field,
        validation: :range
      )
    else
      changeset
    end
  end
end
