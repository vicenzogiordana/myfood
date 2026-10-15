defmodule MealPlannerApi.PlanningAgent.ProjectedPantry do
  @moduledoc """
  The Projected Pantry of a Household (spec #93, user stories 14, 56): the
  usable Pantry minus the stock already committed to Planned Meals not yet
  cooked. Planning always uses the Projected Pantry, so the same stock is
  never allocated twice.

    * Pantry — every usable lot (`MealPlannerApi.Inventory.LotFreshness`);
      expired lots are excluded
    * committed — the ingredients of every not-yet-cooked Planned Meal from
      today on, wherever it falls relative to the Planning Range, scaled by
      the meal's selected quantity. Uncooked meals in the past are not
      counted: they were never cooked and no longer reserve stock.
    * available — on hand minus committed, never below zero

  Quantities are integer milli-units keyed by `{ingredient_id, unit}`; no
  unit conversion is applied.
  """

  import Ecto.Query

  alias MealPlannerApi.Inventory.LotFreshness
  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Persistence.Inventory.InventoryItem
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.RecipeVersions

  @type key :: {Ecto.UUID.t(), :g | :ml | :unit}
  @type entry :: %{
          ingredient_id: Ecto.UUID.t(),
          ingredient: String.t() | nil,
          unit: :g | :ml | :unit,
          on_hand_milli: non_neg_integer(),
          committed_milli: non_neg_integer(),
          available_milli: non_neg_integer()
        }
  @type t :: %{key() => entry()}

  @doc """
  Loads the Projected Pantry of `account_id`. Only ingredients with stock on
  hand appear.
  """
  @spec load(Ecto.UUID.t(), Date.t()) :: t()
  def load(account_id, today \\ Date.utc_today()) do
    on_hand = on_hand(account_id, today)
    committed = committed(account_id, today)
    names = names(on_hand |> Map.keys() |> Enum.map(&elem(&1, 0)))

    Map.new(on_hand, fn {{ingredient_id, unit} = key, quantity} ->
      reserved = Map.get(committed, key, 0)

      {key,
       %{
         ingredient_id: ingredient_id,
         ingredient: Map.get(names, ingredient_id),
         unit: unit,
         on_hand_milli: quantity,
         committed_milli: reserved,
         available_milli: max(quantity - reserved, 0)
       }}
    end)
  end

  @doc "Available quantity per `{ingredient_id, unit}`."
  @spec available(t()) :: %{key() => non_neg_integer()}
  def available(pantry), do: Map.new(pantry, fn {key, entry} -> {key, entry.available_milli} end)

  @doc "JSON-safe entries, sorted by ingredient name."
  @spec to_data(t()) :: [map()]
  def to_data(pantry) do
    pantry
    |> Map.values()
    |> Enum.sort_by(&{&1.ingredient, &1.unit})
    |> Enum.map(fn entry ->
      %{
        "ingredient" => entry.ingredient,
        "unit" => Atom.to_string(entry.unit),
        "on_hand_milli" => entry.on_hand_milli,
        "committed_milli" => entry.committed_milli,
        "available_milli" => entry.available_milli
      }
    end)
  end

  defp on_hand(account_id, today) do
    from(i in InventoryItem, where: i.account_id == ^account_id and i.quantity_milli > 0)
    |> Repo.all()
    |> Enum.filter(&LotFreshness.usable?(&1, today))
    |> Enum.reduce(%{}, fn item, acc ->
      Map.update(
        acc,
        {item.ingredient_id, item.unit},
        item.quantity_milli,
        &(&1 + item.quantity_milli)
      )
    end)
  end

  defp committed(account_id, today) do
    from(m in ScheduledMeal,
      where: m.account_id == ^account_id and m.is_cooked == false and m.date >= ^today,
      where: not is_nil(m.recipe_id),
      preload: [recipe: :recipe_ingredients]
    )
    |> Repo.all()
    |> Enum.flat_map(&meal_ingredients/1)
    |> Enum.reduce(%{}, fn {key, quantity}, acc ->
      Map.update(acc, key, quantity, &(&1 + quantity))
    end)
  end

  # Ingredient requirements of one Planned Meal as `{key, quantity_milli}`.
  # A frozen recipe snapshot already carries the selected quantity; a meal
  # without one is scaled here.
  defp meal_ingredients(%{recipe_snapshot: snapshot} = meal) when is_map(snapshot) do
    case RecipeVersions.recipe_for_meal(meal) do
      %{recipe_ingredients: ingredients} when is_list(ingredients) ->
        Enum.map(ingredients, &{{&1.ingredient_id, &1.unit}, &1.quantity_milli})

      _ ->
        []
    end
  end

  defp meal_ingredients(%{recipe: %{recipe_ingredients: ingredients}} = meal)
       when is_list(ingredients) do
    factor = Map.get(meal, :selected_quantity) || 1
    Enum.map(ingredients, &{{&1.ingredient_id, &1.unit}, &1.quantity_milli * factor})
  end

  defp meal_ingredients(_meal), do: []

  defp names([]), do: %{}

  defp names(ids) do
    from(i in Ingredient, where: i.id in ^Enum.uniq(ids), select: {i.id, i.name})
    |> Repo.all()
    |> Map.new()
  end
end
