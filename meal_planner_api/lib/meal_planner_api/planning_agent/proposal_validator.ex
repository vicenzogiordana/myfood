defmodule MealPlannerApi.PlanningAgent.ProposalValidator do
  @moduledoc """
  Deterministic validation run by `present_proposal` before any Proposal is
  shown (spec #93, user stories 61–64). Validity is owned by code, never by
  the model.

  Checks, for the session's Household and Planning Range:

    * coverage — exactly one meal per day and slot of the range
    * availability — every recipe exists, is visible to the Household, is not
      superseded and suits its slot. An AI-created Recipe Draft of the
      Workspace (`MealPlannerApi.PlanningAgent.RecipeDraft`) counts as
      available; a dictated Draft is not plannable until the Member saves it
    * Restrictions — `MealPlannerApi.Planning.RestrictionValidator` over every
      Member, plus ingredients a Member is allergic to

  Approved Absence Exceptions (`ctx.absence_exceptions`, see
  `MealPlannerApi.PlanningAgent.Session`) lift one Restriction of one Member
  for exactly their meals. Lifting `{:allergy, tag}` also lifts the
  Member's allergic ingredients carrying that tag; an allergy to an
  ingredient without a reviewed allergen tag cannot be lifted.

  The budget is not a violation: `present_proposal` compares the Purchase
  (`MealPlannerApi.PlanningAgent.Purchase`) against it and reports overspend
  as a budget Deviation. Violations are generic and never name a Member.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Catalog.{Recipe, RecipeIngredient}
  alias MealPlannerApi.Planning.{RecipeOrigin, RestrictionValidator}
  alias MealPlannerApi.PlanningAgent.RecipeDraft
  alias MealPlannerApi.Repo

  @type meal :: %{date: Date.t(), slot: String.t(), recipe_id: String.t()}

  @doc """
  Validates `meals`. Returns `{:valid, meals}` with each recipe's `:name`,
  `:origin` (Recipe Origin label) and `:draft` attached, or
  `{:invalid, violations}`.
  """
  @spec validate([meal()], map()) :: {:valid, [map()]} | {:invalid, [map()]}
  def validate(meals, ctx) do
    {from_date, to_date} = ctx.range
    expected = for date <- Date.range(from_date, to_date), slot <- ctx.slots, do: {date, slot}

    drafts =
      ctx |> RecipeDraft.in_context() |> Map.filter(fn {_, d} -> RecipeDraft.plannable?(d) end)

    recipes = meals |> load_recipes(ctx.account_id) |> Map.merge(draft_recipes(meals, drafts))

    violations =
      coverage_violations(meals, expected) ++
        availability_violations(meals, recipes) ++
        restriction_violations(
          meals,
          recipes,
          drafts,
          ctx.household,
          Map.get(ctx, :absence_exceptions, [])
        )

    case violations do
      [] ->
        {:valid,
         Enum.map(meals, fn meal ->
           recipe = Map.fetch!(recipes, meal.recipe_id)
           Map.merge(meal, %{name: recipe.name, origin: recipe.origin, draft: recipe.draft})
         end)}

      _ ->
        {:invalid, violations}
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

  defp restriction_violations(meals, recipes, drafts, household, exceptions) do
    known = Enum.filter(meals, &Map.has_key?(recipes, &1.recipe_id))

    used_drafts =
      known |> Enum.map(& &1.recipe_id) |> Enum.uniq() |> Enum.flat_map(&List.wrap(drafts[&1]))

    tag_conflicts =
      case RestrictionValidator.validate(known, household.members,
             tags_by_recipe: RecipeDraft.reviewed_tags(used_drafts),
             absence_exceptions: exceptions
           ) do
        :ok -> []
        {:error, conflicts} -> Enum.map(conflicts, &{&1.date, &1.slot, &1.message})
      end

    allergic = MapSet.to_list(household.allergic_ingredient_ids)
    lifted = lifted_allergies(exceptions)

    allergic_by_recipe =
      known
      |> allergic_by_recipe(allergic)
      |> Map.merge(allergic_by_draft(used_drafts, household))

    allergy_conflicts =
      for meal <- known,
          ingredient_id <- Map.get(allergic_by_recipe, meal.recipe_id, []),
          not lifted_for_everyone?(household.members, ingredient_id, meal, lifted),
          uniq: true,
          do:
            {meal.date, meal.slot,
             "This meal includes an ingredient that conflicts with a household member's Restriction."}

    (tag_conflicts ++ allergy_conflicts)
    |> Enum.uniq_by(fn {date, slot, _} -> {date, slot} end)
    |> Enum.map(fn {date, slot, message} ->
      violation("restriction_conflict", date, slot, message)
    end)
  end

  # Allergic ingredient ids per Recipe Draft of `drafts`.
  defp allergic_by_draft(drafts, household) do
    for draft <- drafts,
        ids =
          draft
          |> RecipeDraft.ingredient_ids()
          |> Enum.filter(&MapSet.member?(household.allergic_ingredient_ids, &1))
          |> Enum.uniq(),
        ids != [],
        into: %{},
        do: {draft.id, ids}
  end

  defp draft_recipes(meals, drafts) do
    for %{recipe_id: id} <- meals,
        draft = drafts[id],
        draft != nil,
        into: %{},
        do:
          {id,
           %{
             id: id,
             name: draft.name,
             suitable_for_slots: draft.slots,
             origin: RecipeOrigin.label(draft.source),
             draft: true
           }}
  end

  # Allergic ingredient ids per recipe of `meals`.
  defp allergic_by_recipe(_meals, []), do: %{}

  defp allergic_by_recipe(meals, allergic) do
    ids = meals |> Enum.map(& &1.recipe_id) |> Enum.uniq()

    from(ri in RecipeIngredient,
      where: ri.recipe_id in ^ids and ri.ingredient_id in ^allergic,
      distinct: true,
      select: {ri.recipe_id, ri.ingredient_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # An allergic ingredient is allowed at a meal only when every Member
  # allergic to it has an Absence Exception lifting one of its allergen
  # tags at that meal. Other allergen tags it carries are still checked by
  # the tag comparison above. An ingredient no Member claims stays forbidden.
  defp lifted_for_everyone?(members, ingredient_id, meal, lifted) do
    holders =
      for member <- members,
          {:ok, tags} <- [
            member |> Map.get(:allergic_ingredients, %{}) |> Map.fetch(ingredient_id)
          ],
          do: {member.id, tags}

    holders != [] and
      Enum.all?(holders, fn {member_id, tags} ->
        Enum.any?(tags, &MapSet.member?(lifted, {member_id, &1, {meal.date, meal.slot}}))
      end)
  end

  defp lifted_allergies(exceptions) do
    for %{restriction: {:allergy, tag}} = exception <- exceptions,
        key <- exception.meals,
        into: MapSet.new(),
        do: {exception.member_id, tag, key}
  end

  defp load_recipes(meals, account_id) do
    ids = meals |> Enum.map(& &1.recipe_id) |> Enum.flat_map(&cast_uuid/1) |> Enum.uniq()

    from(r in Recipe,
      where: r.id in ^ids,
      where: is_nil(r.superseded_by_id),
      where: is_nil(r.account_id) or r.account_id == ^account_id,
      select: %{
        id: r.id,
        name: r.name,
        suitable_for_slots: r.suitable_for_slots,
        source: r.source
      }
    )
    |> Repo.all()
    |> Map.new(fn recipe ->
      {recipe.id,
       recipe |> Map.put(:origin, RecipeOrigin.label(recipe.source)) |> Map.put(:draft, false)}
    end)
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
