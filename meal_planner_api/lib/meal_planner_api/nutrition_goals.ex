defmodule MealPlannerApi.NutritionGoals do
  @moduledoc """
  Household Nutrition Goal settings (spec #93, user story 20a).

  A Household has at most one Nutrition Goal: a daily range of calories and
  macros per standard portion that the optimizer uses as its numeric target.
  Any Member of the Household may read or replace it; tenancy is enforced by
  the caller passing the Household id resolved from the current membership.

  The public shape groups each range as `%{"min" => integer, "max" => integer}`
  under the keys `calories`, `protein_g`, `carbs_g` and `fat_g`.
  """

  alias MealPlannerApi.Persistence.Accounts.HouseholdNutritionGoal
  alias MealPlannerApi.Repo

  @type range :: %{min: non_neg_integer(), max: non_neg_integer()}
  @type goal :: %{
          account_id: Ecto.UUID.t(),
          period: String.t(),
          per: String.t(),
          calories: range(),
          protein_g: range(),
          carbs_g: range(),
          fat_g: range(),
          updated_at: DateTime.t()
        }

  @doc "Returns the Household's Nutrition Goal, or `nil` when none is set."
  @spec get(Ecto.UUID.t()) :: goal() | nil
  def get(account_id) do
    case Repo.get_by(HouseholdNutritionGoal, account_id: account_id) do
      nil -> nil
      goal -> serialize(goal)
    end
  end

  @doc """
  Creates or fully replaces the Household's Nutrition Goal.

  Every range is required; bounds must be non-negative integers with
  `min <= max`. Returns `{:error, changeset}` when the ranges are invalid,
  leaving any previous goal untouched.
  """
  @spec put(Ecto.UUID.t(), map()) :: {:ok, goal()} | {:error, Ecto.Changeset.t()}
  def put(account_id, ranges) when is_map(ranges) do
    attrs = ranges |> flatten_ranges() |> Map.put(:account_id, account_id)
    changeset = HouseholdNutritionGoal.changeset(%HouseholdNutritionGoal{}, attrs)
    replaced_fields = Map.keys(attrs) -- [:account_id]

    changeset
    |> Repo.insert(
      on_conflict: {:replace, [:updated_at | replaced_fields]},
      conflict_target: :account_id,
      returning: true
    )
    |> case do
      {:ok, goal} -> {:ok, serialize(goal)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp flatten_ranges(ranges) do
    Enum.reduce(HouseholdNutritionGoal.ranges(), %{}, fn range, acc ->
      bounds = fetch_range(ranges, range)

      acc
      |> Map.put(:"#{range}_min", bound(bounds, "min", :min))
      |> Map.put(:"#{range}_max", bound(bounds, "max", :max))
    end)
  end

  defp fetch_range(ranges, range) do
    case Map.get(ranges, Atom.to_string(range), Map.get(ranges, range)) do
      %{} = bounds -> bounds
      _ -> %{}
    end
  end

  defp bound(bounds, string_key, atom_key),
    do: Map.get(bounds, string_key, Map.get(bounds, atom_key))

  defp serialize(%HouseholdNutritionGoal{} = goal) do
    ranges =
      Map.new(HouseholdNutritionGoal.ranges(), fn range ->
        {range,
         %{
           min: Map.fetch!(goal, :"#{range}_min"),
           max: Map.fetch!(goal, :"#{range}_max")
         }}
      end)

    Map.merge(ranges, %{
      account_id: goal.account_id,
      period: "daily",
      per: "standard_portion",
      updated_at: goal.updated_at
    })
  end
end
