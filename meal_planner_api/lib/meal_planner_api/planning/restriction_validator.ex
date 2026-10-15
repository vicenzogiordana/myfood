defmodule MealPlannerApi.Planning.RestrictionValidator do
  @moduledoc """
  Deterministic Restriction check for a set of meals.

  Every Member's Restriction (allergy or diet) is expressed as a set of forbidden
  Ingredient Tags (see `MealPlannerApi.Planning.Restrictions`). A meal conflicts
  when any reviewed tag of its recipe's ingredients is forbidden by a Restriction
  of any Member, unless an approved Absence Exception lifts exactly that
  Restriction of exactly that Member for exactly that meal.

  Only reviewed Ingredient Tags count; suggestions never do. Disliked ingredients
  are Preferences and are never violations.

  Conflicts are generic: they name the meal, the offending ingredients and tags,
  but never the Member holding the Restriction.

  ## Inputs

    * `meals` - `[%{date: Date.t(), slot: String.t(), recipe_id: id}]`
    * `members` - `[%{id: term(), restrictions: [Restrictions.restriction()]}]`;
      other keys (for example dislikes) are ignored
    * `opts[:absence_exceptions]` - approved Absence Exceptions,
      `[%{member_id: term(), restriction: restriction, meals: [{date, slot}]}]`
  """

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Planning.Restrictions

  @message "This meal includes an ingredient that conflicts with a household member's Restriction."

  @type meal :: %{
          required(:date) => Date.t(),
          required(:slot) => String.t(),
          required(:recipe_id) => term()
        }
  @type member :: %{
          required(:id) => term(),
          required(:restrictions) => [Restrictions.restriction()]
        }
  @type absence_exception :: %{
          required(:member_id) => term(),
          required(:restriction) => Restrictions.restriction(),
          required(:meals) => [{Date.t(), String.t()}]
        }
  @type conflict :: %{
          date: Date.t(),
          slot: String.t(),
          recipe_id: term(),
          ingredient_ids: [term()],
          tags: [Restrictions.tag()],
          message: String.t()
        }

  @doc """
  Returns `:ok` when no meal conflicts, or `{:error, conflicts}` in meal order.
  """
  @spec validate([meal()], [member()], keyword()) :: :ok | {:error, [conflict()]}
  def validate(meals, members, opts \\ []) when is_list(meals) and is_list(members) do
    exceptions = opts |> Keyword.get(:absence_exceptions, []) |> lifted_set()
    tags_by_recipe = meals |> Enum.map(& &1.recipe_id) |> Catalog.reviewed_tags_by_recipe()

    meals
    |> Enum.flat_map(fn meal ->
      forbidden = forbidden_for_meal(meal, members, exceptions)
      ingredient_tags = Map.get(tags_by_recipe, meal.recipe_id, %{})
      conflict(meal, ingredient_tags, forbidden)
    end)
    |> case do
      [] -> :ok
      conflicts -> {:error, conflicts}
    end
  end

  defp forbidden_for_meal(meal, members, exceptions) do
    key = {meal.date, meal.slot}

    for member <- members,
        restriction <- Map.get(member, :restrictions, []),
        not MapSet.member?(exceptions, {member.id, restriction, key}),
        tag <- Restrictions.forbidden_tags(restriction),
        into: MapSet.new(),
        do: tag
  end

  defp conflict(meal, ingredient_tags, forbidden) do
    offending =
      for {ingredient_id, tags} <- ingredient_tags,
          hits = MapSet.intersection(tags, forbidden),
          MapSet.size(hits) > 0,
          do: {ingredient_id, hits}

    case offending do
      [] ->
        []

      _ ->
        [
          %{
            date: meal.date,
            slot: meal.slot,
            recipe_id: meal.recipe_id,
            ingredient_ids: offending |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
            tags:
              offending
              |> Enum.reduce(MapSet.new(), fn {_, hits}, acc -> MapSet.union(acc, hits) end)
              |> Enum.sort(),
            message: @message
          }
        ]
    end
  end

  defp lifted_set(exceptions) do
    for exception <- exceptions,
        {date, slot} <- exception.meals,
        into: MapSet.new(),
        do: {exception.member_id, exception.restriction, {date, slot}}
  end
end
