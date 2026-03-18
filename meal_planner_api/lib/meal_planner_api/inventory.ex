defmodule MealPlannerApi.Inventory do
  @moduledoc """
  Inventory context used by planning to reduce food waste.
  """

  alias MealPlannerApi.Accounts.User
  alias MealPlannerApi.Inventory.Item

  @default_items ["oats", "eggs", "chicken", "rice", "broccoli"]

  @spec available_for(User.t(), map()) :: [Item.t()]
  def available_for(%User{}, params \\ %{}) do
    params
    |> Map.get("inventory_items", @default_items)
    |> normalize_items()
  end

  @spec names([Item.t()]) :: [String.t()]
  def names(items), do: Enum.map(items, & &1.name)

  @spec count_hits(String.t(), [Item.t()]) :: non_neg_integer()
  def count_hits(text, items) when is_binary(text) do
    lowered = String.downcase(text)

    items
    |> names()
    |> Enum.count(&String.contains?(lowered, String.downcase(&1)))
  end

  defp normalize_items(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(&%Item{name: &1})
  end

  defp normalize_items(_), do: Enum.map(@default_items, &%Item{name: &1})
end
