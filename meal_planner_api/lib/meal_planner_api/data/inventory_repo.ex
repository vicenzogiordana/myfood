defmodule MealPlannerApi.Data.InventoryRepo do
  @moduledoc """
  Data-facing inventory API.

  Read operations and fixture-compatible creation remain here. Every runtime quantity
  mutation delegates to `MealPlannerApi.Persistence.Inventory`, the canonical audited
  transaction boundary.
  """

  alias MealPlannerApi.Persistence.Inventory, as: InventoryPersistence
  alias MealPlannerApi.Persistence.Inventory.{InventoryItem, InventoryMutationEvent}
  alias MealPlannerApi.Repo

  @spec list_inventory(Ecto.UUID.t()) :: [InventoryItem.t()]
  defdelegate list_inventory(account_id), to: InventoryPersistence

  @spec list_inventory_with_ingredient(Ecto.UUID.t()) :: [InventoryItem.t()]
  defdelegate list_inventory_with_ingredient(account_id), to: InventoryPersistence

  @spec get_inventory_item!(Ecto.UUID.t()) :: InventoryItem.t()
  defdelegate get_inventory_item!(id), to: InventoryPersistence

  @spec get_inventory_item_for_account(Ecto.UUID.t(), Ecto.UUID.t()) :: InventoryItem.t() | nil
  defdelegate get_inventory_item_for_account(account_id, item_id), to: InventoryPersistence

  @spec find_inventory_item_by_ingredient(Ecto.UUID.t(), Ecto.UUID.t(), atom(), atom()) ::
          InventoryItem.t() | nil
  defdelegate find_inventory_item_by_ingredient(account_id, ingredient_id, unit, source_kind),
    to: InventoryPersistence

  @spec update_inventory_item(InventoryItem.t(), map()) ::
          {:ok, InventoryItem.t()} | {:error, term()}
  defdelegate update_inventory_item(item, attrs), to: InventoryPersistence

  @spec upsert_inventory_item(map()) :: {:ok, InventoryItem.t()} | {:error, term()}
  defdelegate upsert_inventory_item(attrs), to: InventoryPersistence

  @doc "Legacy creation seam retained for checkout compatibility; runtime adjustments use apply_delta/1."
  @spec create_inventory_item(map()) :: {:ok, InventoryItem.t()} | {:error, Ecto.Changeset.t()}
  def create_inventory_item(attrs),
    do: %InventoryItem{} |> InventoryItem.changeset(attrs) |> Repo.insert()

  @spec append_mutation(map()) :: {:ok, InventoryMutationEvent.t()} | {:error, Ecto.Changeset.t()}
  defdelegate append_mutation(attrs), to: InventoryPersistence, as: :append_inventory_mutation

  @spec list_mutations(Ecto.UUID.t(), DateTime.t(), DateTime.t()) ::
          [InventoryMutationEvent.t()]
  defdelegate list_mutations(account_id, from_datetime, to_datetime), to: InventoryPersistence

  @spec apply_delta(map()) :: {:ok, map()} | {:error, term()}
  defdelegate apply_delta(opts), to: InventoryPersistence, as: :apply_delta_and_log

  @spec subtract_usable_lots(map()) :: {:ok, map()} | {:error, term()}
  defdelegate subtract_usable_lots(opts),
    to: InventoryPersistence,
    as: :subtract_usable_lots_and_log
end
