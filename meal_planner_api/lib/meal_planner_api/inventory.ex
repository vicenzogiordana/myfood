defmodule MealPlannerApi.Inventory do
  @moduledoc """
  Inventory context used by planning to reduce food waste.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Inventory.InventoryItem
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Persistence.Catalog.RecipeIngredient

  @spec available_for(map(), map()) :: [map()]
  def available_for(user, params \\ %{}) when is_map(user) and is_map(params) do
    _ = params

    case Map.get(user, :account_id) do
      account_id when is_binary(account_id) ->
        case Ecto.UUID.cast(account_id) do
          {:ok, _} ->
            physical_items = load_physical_inventory(account_id)
            reserved_by_key = load_reserved_future_quantities(account_id)
            apply_reservations(physical_items, reserved_by_key, account_id)

          :error ->
            []
        end

      _ ->
        []
    end
  end

  @spec count_hits(String.t(), [map()]) :: non_neg_integer()
  def count_hits(text, items) when is_binary(text) do
    lowered = String.downcase(text)

    items
    |> names()
    |> Enum.count(&String.contains?(lowered, String.downcase(&1)))
  end

  def names(items) when is_list(items) do
    items
    |> Enum.map(&item_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp item_name(%InventoryItem{ingredient: %{name: name}}) when is_binary(name), do: name
  defp item_name(%{ingredient: %{name: name}}) when is_binary(name), do: name
  defp item_name(%{name: name}) when is_binary(name), do: name
  defp item_name(_), do: nil

  defp load_physical_inventory(account_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id and i.quantity_milli > 0,
      preload: [:ingredient],
      order_by: [asc: i.ingredient_id]
    )
    |> Repo.all()
  end

  defp load_reserved_future_quantities(account_id) do
    today = Date.utc_today()

    from(m in ScheduledMeal,
      join: ri in RecipeIngredient,
      on: ri.recipe_id == m.recipe_id,
      where: m.account_id == ^account_id and m.is_cooked == false and m.date > ^today,
      group_by: [ri.ingredient_id, ri.unit],
      select: {ri.ingredient_id, ri.unit, sum(ri.quantity_milli)}
    )
    |> Repo.all()
    |> Map.new(fn {ingredient_id, unit, quantity} -> {{ingredient_id, unit}, quantity || 0} end)
  end

  defp apply_reservations(physical_items, reserved_by_key, account_id) do
    grouped =
      Enum.group_by(physical_items, fn item -> {item.ingredient_id, item.unit} end)

    grouped
    |> Enum.map(fn {{ingredient_id, unit}, items} ->
      first = hd(items)
      total_quantity = Enum.reduce(items, 0, fn item, acc -> acc + item.quantity_milli end)
      reserved = Map.get(reserved_by_key, {ingredient_id, unit}, 0)
      available = max(total_quantity - reserved, 0)

      %{
        account_id: account_id,
        ingredient_id: ingredient_id,
        ingredient: first.ingredient,
        unit: unit,
        quantity_milli: available
      }
    end)
    |> Enum.filter(&(&1.quantity_milli > 0))
    |> Enum.sort_by(&{&1.ingredient_id, &1.unit})
  end
end
