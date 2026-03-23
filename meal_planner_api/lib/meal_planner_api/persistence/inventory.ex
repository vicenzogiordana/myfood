defmodule MealPlannerApi.Persistence.Inventory do
  @moduledoc "Persistence helpers for inventory and mutation events."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Inventory.{
    InventoryItem,
    InventoryMutationEvent
  }

  def list_inventory(account_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id,
      order_by: [asc: i.ingredient_id]
    )
    |> Repo.all()
  end

  def list_inventory_with_ingredient(account_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id,
      order_by: [asc: i.ingredient_id],
      preload: [:ingredient]
    )
    |> Repo.all()
  end

  def get_inventory_item_for_account(account_id, item_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id and i.id == ^item_id,
      preload: [:ingredient],
      limit: 1
    )
    |> Repo.one()
  end

  def update_inventory_item(item, attrs) do
    item
    |> InventoryItem.changeset(attrs)
    |> Repo.update()
  end

  def upsert_inventory_item(attrs) do
    query =
      from(i in InventoryItem,
        where:
          i.account_id == ^attrs.account_id and i.ingredient_id == ^attrs.ingredient_id and
            i.unit == ^attrs.unit and i.source_kind == ^attrs.source_kind
      )

    case Repo.one(query) do
      nil -> %InventoryItem{} |> InventoryItem.changeset(attrs) |> Repo.insert()
      item -> item |> InventoryItem.changeset(attrs) |> Repo.update()
    end
  end

  def append_inventory_mutation(attrs) do
    %InventoryMutationEvent{}
    |> InventoryMutationEvent.changeset(attrs)
    |> Repo.insert()
  end

  def apply_delta_and_log(
        %{
          account_id: account_id,
          ingredient_id: ingredient_id,
          unit: unit,
          source_kind: source_kind,
          delta: delta,
          source_user_id: source_user_id
        } = opts
      ) do
    query =
      from(i in InventoryItem,
        where:
          i.account_id == ^account_id and i.ingredient_id == ^ingredient_id and i.unit == ^unit and
            i.source_kind == ^source_kind
      )

    Multi.new()
    |> Multi.run(:item_state, fn repo, _ ->
      case repo.one(query) do
        nil ->
          before_qty = 0
          after_qty = max(delta, 0)

          attrs = %{
            account_id: account_id,
            ingredient_id: ingredient_id,
            quantity_milli: after_qty,
            unit: unit,
            source_kind: source_kind,
            last_mutation_at: DateTime.utc_now()
          }

          case %InventoryItem{}
               |> InventoryItem.changeset(attrs)
               |> repo.insert() do
            {:ok, item} -> {:ok, %{item: item, before_qty: before_qty, after_qty: after_qty}}
            {:error, changeset} -> {:error, changeset}
          end

        item ->
          before_qty = item.quantity_milli
          after_qty = max(item.quantity_milli + delta, 0)

          case item
               |> InventoryItem.changeset(%{
                 quantity_milli: after_qty,
                 last_mutation_at: DateTime.utc_now()
               })
               |> repo.update() do
            {:ok, updated_item} ->
              {:ok, %{item: updated_item, before_qty: before_qty, after_qty: after_qty}}

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    end)
    |> Multi.run(:mutation_event, fn repo,
                                     %{
                                       item_state: %{
                                         item: item,
                                         before_qty: before_qty,
                                         after_qty: after_qty
                                       }
                                     } ->
      event_attrs = %{
        account_id: account_id,
        inventory_item_id: item.id,
        trigger_type: opts[:trigger_type] || :manual,
        operation: opts[:operation] || if(delta >= 0, do: :add, else: :subtract),
        quantity_before_milli: before_qty,
        quantity_delta_milli: delta,
        quantity_after_milli: after_qty,
        source_checkout_session_id: opts[:source_checkout_session_id],
        source_cooking_session_id: opts[:source_cooking_session_id],
        source_user_id: source_user_id,
        raw_voice_text: opts[:raw_voice_text],
        metadata: opts[:metadata] || %{}
      }

      %InventoryMutationEvent{}
      |> InventoryMutationEvent.changeset(event_attrs)
      |> repo.insert()
    end)
    |> Repo.transaction()
  end
end
