defmodule MealPlannerApi.PlanningAgent.Diners do
  @moduledoc """
  The diners of each Planned Meal (issue #152, spec #93) and how many
  batches of its recipe they need.

  The diners of a meal are the Household Members present plus that meal's
  guests. Every Member counts as present unless an approved Absence
  Exception covers that meal (`ctx.absence_exceptions`); guests are set per
  day and slot in the Workspace (`set_guests`). A meal buys
  `ceil(diners / recipe servings)` batches of its recipe, and the Purchase,
  consumed cost, budget check, confirmation and Projected Pantry all use
  those batches. A recipe without servings counts as one batch, and a
  Planned Meal is cooked at least once even when no one is present.

  Guest restrictions are volunteered by the household, never asked for. They
  apply to their meal only, as a hard rule checked by code
  (`conflicts/2`), and never change the Household's Restrictions. The
  Nutrition Goal ignores guests: it stays per standard portion.
  """

  alias MealPlannerApi.Planning.{Restrictions, RestrictionValidator}
  alias MealPlannerApi.PlanningAgent.RecipeDraft

  @max_guests 50
  @guest_message "This meal includes an ingredient that conflicts with a guest's Restriction."

  @type key :: {Date.t(), String.t()}
  @type guests :: %{count: pos_integer(), restrictions: [Restrictions.restriction()]}

  @doc "The most guests one meal may have."
  @spec max_guests() :: pos_integer()
  def max_guests, do: @max_guests

  @doc "The guests of the session context `ctx`, by day and slot."
  @spec guests(map()) :: %{key() => guests()}
  def guests(%{guests: guests}) when is_map(guests), do: guests
  def guests(%{workspace: workspace}), do: Map.get(workspace, :guests, %{})
  def guests(_ctx), do: %{}

  @doc """
  Attaches `:members` (present), `:guests`, `:diners` and `:batches` to each
  meal. A meal's `:servings` (attached by the validator) sets its batches.
  """
  @spec annotate([map()], map()) :: [map()]
  def annotate(meals, ctx) do
    members = ctx.household.members |> Enum.map(& &1.id) |> MapSet.new()
    absent = absent_by_meal(ctx, members)
    guests = guests(ctx)

    Enum.map(meals, fn meal ->
      key = {meal.date, meal.slot}
      present = MapSet.size(members) - MapSet.size(Map.get(absent, key, MapSet.new()))
      count = guests |> Map.get(key, %{count: 0}) |> Map.fetch!(:count)
      diners = present + count

      Map.merge(meal, %{
        members: present,
        guests: count,
        diners: diners,
        batches: batches(diners, Map.get(meal, :servings))
      })
    end)
  end

  @doc "Batches of a recipe of `servings` for `diners`: at least one."
  @spec batches(non_neg_integer(), pos_integer() | nil) :: pos_integer()
  def batches(diners, servings) when is_integer(servings) and servings > 0,
    do: max(div(diners + servings - 1, servings), 1)

  def batches(_diners, _servings), do: 1

  @doc """
  Parses the `set_guests` arguments: a guest count (0 clears the meal's
  guests) and optional `guest_restrictions`, each an allergen tag (e.g.
  `"peanut"`) or a diet (e.g. `"vegetarian"`).
  """
  @spec parse(map()) :: {:ok, guests() | nil} | {:error, String.t()}
  def parse(args) do
    with {:ok, count} <- count(Map.get(args, "guests")),
         {:ok, restrictions} <- restrictions(Map.get(args, "guest_restrictions", [])) do
      cond do
        count == 0 and restrictions != [] -> {:error, "guest_restrictions_need_guests"}
        count == 0 -> {:ok, nil}
        true -> {:ok, %{count: count, restrictions: restrictions}}
      end
    end
  end

  @doc "The accepted guest restriction names."
  @spec restriction_names() :: [String.t()]
  def restriction_names do
    diets = for diet <- Restrictions.diets(), diet != :omnivore, do: Atom.to_string(diet)
    Enum.sort(diets) ++ Enum.map(Restrictions.allergen_tags(), &Atom.to_string/1)
  end

  @doc "JSON-safe guests of one meal."
  @spec data(key(), guests()) :: map()
  def data({date, slot}, guests) do
    %{
      "date" => Date.to_iso8601(date),
      "slot" => slot,
      "guests" => guests.count,
      "guest_restrictions" => Enum.map(guests.restrictions, &restriction_name/1)
    }
  end

  @doc "The generic message of a guest-restriction conflict; it names no guest."
  @spec conflict_message() :: String.t()
  def conflict_message, do: @guest_message

  @doc """
  The meals of `meals` whose recipe breaks a guest restriction of that meal.
  Recipe Drafts of the context are checked by their reviewed tags.
  """
  @spec conflicts([map()], map()) :: [map()]
  def conflicts(meals, ctx) do
    guests = guests(ctx)

    restricted =
      Enum.filter(meals, fn meal ->
        case Map.get(guests, {meal.date, meal.slot}) do
          %{restrictions: [_ | _]} -> true
          _ -> false
        end
      end)

    case restricted do
      [] -> []
      _ -> check(restricted, guests, ctx)
    end
  end

  defp check(meals, guests, ctx) do
    drafts = RecipeDraft.in_context(ctx)

    used_drafts =
      meals |> Enum.map(& &1.recipe_id) |> Enum.uniq() |> Enum.flat_map(&List.wrap(drafts[&1]))

    tags = RecipeDraft.reviewed_tags(used_drafts)

    conflicting =
      meals
      |> Enum.group_by(&{&1.date, &1.slot})
      |> Enum.flat_map(fn {key, key_meals} ->
        guest = %{id: :guest, restrictions: guests[key].restrictions}

        case RestrictionValidator.validate(key_meals, [guest], tags_by_recipe: tags) do
          :ok -> []
          {:error, conflicts} -> Enum.map(conflicts, &{&1.date, &1.slot, &1.recipe_id})
        end
      end)
      |> MapSet.new()

    Enum.filter(meals, &MapSet.member?(conflicting, {&1.date, &1.slot, &1.recipe_id}))
  end

  defp absent_by_meal(ctx, members) do
    for exception <- absence_exceptions(ctx),
        MapSet.member?(members, exception.member_id),
        key <- exception.meals,
        reduce: %{} do
      acc ->
        Map.update(
          acc,
          key,
          MapSet.new([exception.member_id]),
          &MapSet.put(&1, exception.member_id)
        )
    end
  end

  defp absence_exceptions(%{absence_exceptions: exceptions}) when is_list(exceptions),
    do: exceptions

  defp absence_exceptions(%{workspace: workspace}),
    do: Map.get(workspace, :absence_exceptions, [])

  defp absence_exceptions(_ctx), do: []

  defp count(count) when is_integer(count) and count >= 0 and count <= @max_guests,
    do: {:ok, count}

  defp count(_count), do: {:error, "invalid_guests"}

  defp restrictions(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case restriction(name) do
        {:ok, restriction} -> {:cont, {:ok, acc ++ [restriction]}}
        :error -> {:halt, {:error, "invalid_guest_restriction"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.uniq(list)}
      error -> error
    end
  end

  defp restrictions(_names), do: {:error, "invalid_guest_restriction"}

  defp restriction(name) when is_binary(name) do
    name = name |> String.trim() |> String.downcase()

    diet = Enum.find(Restrictions.diets(), &(Atom.to_string(&1) == name and &1 != :omnivore))
    allergen = Enum.find(Restrictions.allergen_tags(), &(Atom.to_string(&1) == name))

    cond do
      diet -> {:ok, {:diet, diet}}
      allergen -> {:ok, {:allergy, allergen}}
      true -> :error
    end
  end

  defp restriction(_name), do: :error

  defp restriction_name({_kind, value}), do: Atom.to_string(value)
end
