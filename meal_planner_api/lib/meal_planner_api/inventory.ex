defmodule MealPlannerApi.Inventory do
  @moduledoc """
  Inventory context used by planning to reduce food waste.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Inventory.InventoryItem

  @spec available_for(map(), map()) :: [InventoryItem.t()]
  def available_for(user, params \\ %{}) when is_map(user) and is_map(params) do
    _ = params

    case Map.get(user, :account_id) do
      account_id when is_binary(account_id) ->
        case Ecto.UUID.cast(account_id) do
          {:ok, _} ->
            from(i in InventoryItem,
              where: i.account_id == ^account_id and i.quantity_milli > 0,
              preload: [:ingredient],
              order_by: [asc: i.ingredient_id]
            )
            |> Repo.all()

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
end
