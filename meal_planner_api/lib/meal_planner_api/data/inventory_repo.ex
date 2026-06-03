defmodule MealPlannerApi.Data.InventoryRepo do
  @moduledoc """
  Pure data access for inventory items and mutation events.

  No business logic. No orchestration. Just queries and persistence.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Inventory.{InventoryItem, InventoryMutationEvent}

  # -------------------------------------------------------------------------
  # Inventory items
  # -------------------------------------------------------------------------

  @spec list_inventory(pos_integer()) :: [InventoryItem.t()]
  def list_inventory(account_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id,
      order_by: [asc: i.ingredient_id]
    )
    |> Repo.all()
  end

  @spec list_inventory_with_ingredient(pos_integer()) :: [InventoryItem.t()]
  def list_inventory_with_ingredient(account_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id,
      order_by: [asc: i.ingredient_id],
      preload: [:ingredient]
    )
    |> Repo.all()
  end

  @spec get_inventory_item!(pos_integer()) :: InventoryItem.t()
  def get_inventory_item!(id), do: Repo.get!(InventoryItem, id)

  @spec get_inventory_item_for_account(pos_integer(), pos_integer()) :: InventoryItem.t() | nil
  def get_inventory_item_for_account(account_id, item_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id and i.id == ^item_id,
      preload: [:ingredient],
      limit: 1
    )
    |> Repo.one()
  end

  @spec find_inventory_item_by_ingredient(pos_integer(), pos_integer(), atom(), atom()) ::
          InventoryItem.t() | nil
  def find_inventory_item_by_ingredient(account_id, ingredient_id, unit, source_kind) do
    from(i in InventoryItem,
      where:
        i.account_id == ^account_id and i.ingredient_id == ^ingredient_id and
          i.unit == ^unit and i.source_kind == ^source_kind,
      limit: 1
    )
    |> Repo.one()
  end

  @spec update_inventory_item(InventoryItem.t(), map()) ::
          {:ok, InventoryItem.t()} | {:error, Ecto.Changeset.t()}
  def update_inventory_item(item, attrs),
    do: item |> InventoryItem.changeset(attrs) |> Repo.update()

  @spec upsert_inventory_item(map()) :: {:ok, InventoryItem.t()} | {:error, Ecto.Changeset.t()}
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

  @spec create_inventory_item(map()) :: {:ok, InventoryItem.t()} | {:error, Ecto.Changeset.t()}
  def create_inventory_item(attrs),
    do: %InventoryItem{} |> InventoryItem.changeset(attrs) |> Repo.insert()

  # -------------------------------------------------------------------------
  # Mutation events
  # -------------------------------------------------------------------------

  @spec append_mutation(map()) :: {:ok, InventoryMutationEvent.t()} | {:error, Ecto.Changeset.t()}
  def append_mutation(attrs),
    do: %InventoryMutationEvent{} |> InventoryMutationEvent.changeset(attrs) |> Repo.insert()

  @spec list_mutations(pos_integer(), Date.t(), Date.t()) :: [InventoryMutationEvent.t()]
  def list_mutations(account_id, from_date, to_date) do
    from(e in InventoryMutationEvent,
      join: i in assoc(e, :inventory_item),
      where:
        i.account_id == ^account_id and e.occurred_at >= ^from_date and e.occurred_at <= ^to_date,
      order_by: [desc: e.occurred_at],
      preload: [:inventory_item]
    )
    |> Repo.all()
  end

  # -------------------------------------------------------------------------
  # Atomic delta (transaction)
  # -------------------------------------------------------------------------

  @spec apply_delta(%{
          required(:account_id) => pos_integer(),
          required(:ingredient_id) => pos_integer(),
          required(:unit) => atom(),
          required(:source_kind) => atom(),
          required(:delta) => integer(),
          required(:source_user_id) => pos_integer() | nil,
          optional(:trigger_type) => atom(),
          optional(:operation) => atom(),
          optional(:source_checkout_session_id) => pos_integer() | nil,
          optional(:source_cooking_session_id) => pos_integer() | nil,
          optional(:raw_voice_text) => String.t() | nil,
          optional(:metadata) => map()
        }) ::
          {:ok, %{item: InventoryItem.t(), before_qty: integer(), after_qty: integer()}}
          | {:error, Ecto.Changeset.t()}
  def apply_delta(opts) do
    %{
      account_id: account_id,
      ingredient_id: ingredient_id,
      unit: unit,
      source_kind: source_kind,
      delta: delta,
      source_user_id: source_user_id
    } = opts

    query =
      from(i in InventoryItem,
        where:
          i.account_id == ^account_id and i.ingredient_id == ^ingredient_id and
            i.unit == ^unit and i.source_kind == ^source_kind
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
        operation: if(delta >= 0, do: :add, else: :subtract),
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
