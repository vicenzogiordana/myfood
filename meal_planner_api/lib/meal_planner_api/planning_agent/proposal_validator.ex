defmodule MealPlannerApi.PlanningAgent.ProposalValidator do
  @moduledoc """
  Deterministic validation run by `present_proposal` before any Proposal is
  shown (spec #93, user stories 61–64). Validity is owned by code, never by
  the model.

  Checks, for the session's Household and Planning Range:

    * coverage — exactly one meal per day and slot of the range
    * availability — every recipe exists, is visible to the Household, is not
      superseded and suits its slot
    * Restrictions — `MealPlannerApi.Planning.RestrictionValidator` over every
      Member, plus ingredients a Member is allergic to

  The budget is not a violation: `present_proposal` compares the Purchase
  (`MealPlannerApi.PlanningAgent.Purchase`) against it and reports overspend
  as a budget Deviation. Violations are generic and never name a Member.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Catalog.{Recipe, RecipeIngredient}
  alias MealPlannerApi.Planning.RestrictionValidator
  alias MealPlannerApi.Repo

  @type meal :: %{date: Date.t(), slot: String.t(), recipe_id: String.t()}

  @doc """
  Validates `meals`. Returns `{:valid, meals}` with recipe names attached, or
  `{:invalid, violations}`.
  """
  @spec validate([meal()], map()) :: {:valid, [map()]} | {:invalid, [map()]}
  def validate(meals, ctx) do
    {from_date, to_date} = ctx.range
    expected = for date <- Date.range(from_date, to_date), slot <- ctx.slots, do: {date, slot}

    recipes = load_recipes(meals, ctx.account_id)

    violations =
      coverage_violations(meals, expected) ++
        availability_violations(meals, recipes) ++
        restriction_violations(meals, recipes, ctx.household)

    case violations do
      [] -> {:valid, Enum.map(meals, &Map.put(&1, :name, Map.fetch!(recipes, &1.recipe_id).name))}
      _ -> {:invalid, violations}
    end
  end

  defp coverage_violations(meals, expected) do
    counts = Enum.frequencies_by(meals, &{&1.date, &1.slot})

    missing =
      for {date, slot} <- expected,
          not Map.has_key?(counts, {date, slot}),
          do: violation("missing_meal", date, slot, "No meal is planned for this day and slot.")

    expected_set = MapSet.new(expected)

    unexpected =
      for {{date, slot}, count} <- counts,
          not MapSet.member?(expected_set, {date, slot}) or count > 1,
          do:
            violation(
              "unexpected_meal",
              date,
              slot,
              "This day and slot is outside the Planning Range or planned more than once."
            )

    missing ++ Enum.sort_by(unexpected, &{&1["date"], &1["slot"]})
  end

  defp availability_violations(meals, recipes) do
    Enum.flat_map(meals, fn meal ->
      case Map.fetch(recipes, meal.recipe_id) do
        :error ->
          [
            violation(
              "recipe_not_available",
              meal.date,
              meal.slot,
              "This recipe is not available."
            )
          ]

        {:ok, recipe} ->
          if meal.slot in recipe.suitable_for_slots,
            do: [],
            else: [
              violation(
                "slot_mismatch",
                meal.date,
                meal.slot,
                "This recipe does not suit the slot."
              )
            ]
      end
    end)
  end

  defp restriction_violations(meals, recipes, household) do
    known = Enum.filter(meals, &Map.has_key?(recipes, &1.recipe_id))

    tag_conflicts =
      case RestrictionValidator.validate(known, household.members) do
        :ok -> []
        {:error, conflicts} -> Enum.map(conflicts, &{&1.date, &1.slot, &1.message})
      end

    allergic = MapSet.to_list(household.allergic_ingredient_ids)

    allergy_recipes =
      if allergic == [] do
        MapSet.new()
      else
        ids = known |> Enum.map(& &1.recipe_id) |> Enum.uniq()

        from(ri in RecipeIngredient,
          where: ri.recipe_id in ^ids and ri.ingredient_id in ^allergic,
          distinct: true,
          select: ri.recipe_id
        )
        |> Repo.all()
        |> MapSet.new()
      end

    allergy_conflicts =
      for meal <- known,
          MapSet.member?(allergy_recipes, meal.recipe_id),
          do:
            {meal.date, meal.slot,
             "This meal includes an ingredient that conflicts with a household member's Restriction."}

    (tag_conflicts ++ allergy_conflicts)
    |> Enum.uniq_by(fn {date, slot, _} -> {date, slot} end)
    |> Enum.map(fn {date, slot, message} ->
      violation("restriction_conflict", date, slot, message)
    end)
  end

  defp load_recipes(meals, account_id) do
    ids = meals |> Enum.map(& &1.recipe_id) |> Enum.flat_map(&cast_uuid/1) |> Enum.uniq()

    from(r in Recipe,
      where: r.id in ^ids,
      where: is_nil(r.superseded_by_id),
      where: is_nil(r.account_id) or r.account_id == ^account_id,
      select: %{id: r.id, name: r.name, suitable_for_slots: r.suitable_for_slots}
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> [uuid]
      :error -> []
    end
  end

  defp violation(type, date, slot, message) do
    %{"type" => type, "date" => Date.to_iso8601(date), "slot" => slot, "message" => message}
  end
end
