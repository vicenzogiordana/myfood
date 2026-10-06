defmodule MealPlannerApi.Persistence.Inventory do
  @moduledoc """
  Canonical persistence boundary for inventory lots and their mutation events.

  Quantity changes are serialized and audited in the same transaction. Ingredient-level
  additions without lot metadata accumulate in the oldest anonymous lot; metadata-bearing
  additions remain distinct lots. Ingredient-level subtraction consumes usable lots in a
  stable FEFO order.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Inventory.LotFreshness
  alias MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Inventory.{
    InventoryItem,
    InventoryMutationEvent
  }

  @lot_fields [:acquired_at, :expired_at, :acquired_price_cents]

  def list_inventory(account_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id,
      order_by: [asc: i.ingredient_id, asc: i.inserted_at, asc: i.id]
    )
    |> Repo.all()
  end

  def list_inventory_with_ingredient(account_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id,
      order_by: [asc: i.ingredient_id, asc: i.inserted_at, asc: i.id],
      preload: [:ingredient]
    )
    |> Repo.all()
  end

  def get_inventory_item!(id), do: Repo.get!(InventoryItem, id)

  def get_inventory_item_for_account(account_id, item_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id and i.id == ^item_id,
      preload: [:ingredient],
      limit: 1
    )
    |> Repo.one()
  end

  def find_inventory_item_by_ingredient(account_id, ingredient_id, unit, source_kind) do
    normalized_unit = normalize_unit(unit)
    normalized_source = normalize_source_kind(source_kind)

    from(i in InventoryItem,
      where:
        i.account_id == ^account_id and i.ingredient_id == ^ingredient_id and
          i.unit == ^normalized_unit and i.source_kind == ^normalized_source,
      order_by: [
        asc:
          fragment(
            "CASE WHEN ? IS NULL AND ? IS NULL AND ? IS NULL THEN 0 ELSE 1 END",
            i.acquired_at,
            i.expired_at,
            i.acquired_price_cents
          ),
        asc_nulls_last: i.expired_at,
        asc_nulls_last: i.acquired_at,
        asc: i.inserted_at,
        asc: i.id
      ],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Quantity changes must use apply_delta_and_log/1. Metadata-only updates remain supported."
  def update_inventory_item(item, attrs) do
    if has_quantity?(attrs) do
      {:error, :audited_quantity_mutation_required}
    else
      item |> InventoryItem.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Creates a legacy fixture/producer row, but refuses to overwrite an existing lot quantity."
  def upsert_inventory_item(attrs) do
    account_id = value(attrs, :account_id)
    ingredient_id = value(attrs, :ingredient_id)
    unit = normalize_unit(value(attrs, :unit))
    source_kind = normalize_source_kind(value(attrs, :source_kind))

    case find_inventory_item_by_ingredient(account_id, ingredient_id, unit, source_kind) do
      nil -> %InventoryItem{} |> InventoryItem.changeset(attrs) |> Repo.insert()
      _item -> {:error, :audited_quantity_mutation_required}
    end
  end

  def append_inventory_mutation(attrs) do
    %InventoryMutationEvent{}
    |> InventoryMutationEvent.changeset(attrs)
    |> Repo.insert()
  end

  def list_mutations(account_id, %DateTime{} = from_datetime, %DateTime{} = to_datetime)
      when is_binary(account_id) do
    from(e in InventoryMutationEvent,
      join: i in assoc(e, :inventory_item),
      where:
        i.account_id == ^account_id and e.account_id == ^account_id and
          e.inserted_at >= ^from_datetime and e.inserted_at <= ^to_datetime,
      order_by: [desc: e.inserted_at],
      preload: [:inventory_item]
    )
    |> Repo.all()
  end

  @doc """
  Applies one audited lot mutation, or consumes multiple usable lots for an
  ingredient-level subtraction. All item and event changes share one transaction.
  """
  def apply_delta_and_log(opts) when is_map(opts) do
    mutation = normalize_mutation(opts)

    if is_nil(mutation.item_id) and not mutation.set? and not mutation.delete? and
         mutation.delta < 0 do
      subtract_usable_lots_and_log(opts)
    else
      apply_single_lot_and_log(mutation)
    end
  end

  def apply_delta(opts), do: apply_delta_and_log(opts)

  @doc """
  Subtracts a requested quantity across usable lots in stable FEFO order.

  Expired and zero-quantity lots are not touched. If requested stock is absent, the
  operation succeeds with an applied delta of zero and creates neither a zero lot nor
  a mutation event.
  """
  def subtract_usable_lots_and_log(opts) when is_map(opts) do
    mutation = normalize_mutation(opts)
    requested = abs(mutation.delta)
    today = Date.utc_today()

    Repo.transaction(fn ->
      lock_logical_key!(Repo, mutation)
      lots = lock_usable_lots(Repo, mutation, today)

      {states, events, remaining} =
        Enum.reduce_while(lots, {[], [], requested}, fn lot, {states, events, remaining} ->
          if remaining == 0 do
            {:halt, {states, events, remaining}}
          else
            applied = min(lot.quantity_milli, remaining)
            after_qty = lot.quantity_milli - applied
            updated = update_quantity!(Repo, lot, after_qty)

            state = %{
              item: updated,
              before_qty: lot.quantity_milli,
              after_qty: after_qty,
              delta: -applied
            }

            event = insert_event!(Repo, state, mutation, :subtract)
            {:cont, {[state | states], [event | events], remaining - applied}}
          end
        end)

      states = Enum.reverse(states)
      events = Enum.reverse(events)
      applied = requested - remaining

      %{
        item_states: states,
        mutation_events: events,
        item: states |> List.last() |> state_item(),
        mutation_event: List.last(events),
        before_qty: Enum.sum(Enum.map(states, & &1.before_qty)),
        after_qty: Enum.sum(Enum.map(states, & &1.after_qty)),
        delta: -applied
      }
    end)
    |> unwrap_transaction()
  end

  defp apply_single_lot_and_log(mutation) do
    Repo.transaction(fn ->
      lock_mutation_key!(Repo, mutation)
      item = lock_single_lot(Repo, mutation)

      case item do
        nil when not is_nil(mutation.item_id) ->
          Repo.rollback(:item_not_found)

        nil ->
          create_lot_or_noop(Repo, mutation)

        %InventoryItem{} = existing ->
          mutate_existing_lot(Repo, existing, mutation)
      end
    end)
    |> unwrap_transaction()
  end

  defp create_lot_or_noop(_repo, %{delete?: true}), do: empty_result()

  defp create_lot_or_noop(repo, mutation) do
    after_qty =
      if mutation.set?,
        do: max(mutation.target_qty || mutation.delta, 0),
        else: max(mutation.delta, 0)

    if after_qty == 0 do
      empty_result()
    else
      attrs = %{
        account_id: mutation.account_id,
        ingredient_id: mutation.ingredient_id,
        quantity_milli: after_qty,
        unit: mutation.unit,
        source_kind: mutation.source_kind,
        acquired_at: mutation.lot_metadata.acquired_at,
        expired_at: mutation.lot_metadata.expired_at,
        acquired_price_cents: mutation.lot_metadata.acquired_price_cents,
        last_mutation_at: DateTime.utc_now()
      }

      item =
        %InventoryItem{}
        |> InventoryItem.changeset(attrs)
        |> insert_item!(repo)
        |> repo.preload([:ingredient])

      state = %{item: item, before_qty: 0, after_qty: after_qty, delta: after_qty}
      event = insert_event!(repo, state, mutation, event_operation(mutation, after_qty))
      result(state, event)
    end
  end

  defp mutate_existing_lot(repo, existing, mutation) do
    before_qty = existing.quantity_milli

    after_qty =
      cond do
        mutation.delete? -> 0
        mutation.set? -> max(mutation.target_qty || before_qty + mutation.delta, 0)
        true -> max(before_qty + mutation.delta, 0)
      end

    actual_delta = after_qty - before_qty
    updated = update_quantity!(repo, existing, after_qty)
    state = %{item: updated, before_qty: before_qty, after_qty: after_qty, delta: actual_delta}
    event = insert_event!(repo, state, mutation, event_operation(mutation, actual_delta))
    result(state, event)
  end

  defp lock_single_lot(repo, %{item_id: item_id, account_id: account_id})
       when not is_nil(item_id) do
    from(i in InventoryItem,
      where: i.account_id == ^account_id and i.id == ^item_id,
      lock: "FOR UPDATE"
    )
    |> repo.one()
    |> preload_item(repo)
  end

  defp lock_single_lot(repo, mutation) do
    base =
      from(i in InventoryItem,
        where:
          i.account_id == ^mutation.account_id and
            i.ingredient_id == ^mutation.ingredient_id and i.unit == ^mutation.unit and
            i.source_kind == ^mutation.source_kind,
        lock: "FOR UPDATE",
        limit: 1
      )

    query =
      if metadata_bearing?(mutation.lot_metadata) do
        from(i in base, order_by: [asc: i.inserted_at, asc: i.id], where: false)
      else
        from(i in base,
          where:
            is_nil(i.acquired_at) and is_nil(i.expired_at) and is_nil(i.acquired_price_cents),
          order_by: [asc: i.inserted_at, asc: i.id]
        )
      end

    query |> repo.one() |> preload_item(repo)
  end

  defp lock_usable_lots(repo, mutation, today) do
    from(i in InventoryItem,
      where:
        i.account_id == ^mutation.account_id and
          i.ingredient_id == ^mutation.ingredient_id and i.unit == ^mutation.unit and
          i.source_kind == ^mutation.source_kind and i.quantity_milli > 0,
      order_by: [asc: i.inserted_at, asc: i.id],
      lock: "FOR UPDATE"
    )
    |> repo.all()
    |> repo.preload([:ingredient])
    |> Enum.filter(&LotFreshness.usable?(&1, today))
    |> Enum.sort_by(&LotFreshness.fefo_sort_key(&1, today))
  end

  defp lock_mutation_key!(repo, %{item_id: item_id} = mutation) when not is_nil(item_id) do
    advisory_lock!(repo, "inventory:#{mutation.account_id}:item:#{item_id}")
  end

  defp lock_mutation_key!(repo, mutation), do: lock_logical_key!(repo, mutation)

  defp lock_logical_key!(repo, mutation) do
    advisory_lock!(
      repo,
      "inventory:#{mutation.account_id}:#{mutation.ingredient_id}:#{mutation.unit}:#{mutation.source_kind}"
    )
  end

  defp advisory_lock!(repo, key) do
    case repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp update_quantity!(repo, item, quantity) do
    item
    |> InventoryItem.changeset(%{
      quantity_milli: quantity,
      last_mutation_at: DateTime.utc_now()
    })
    |> repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp insert_item!(changeset, repo) do
    case repo.insert(changeset) do
      {:ok, item} -> item
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp insert_event!(repo, state, mutation, operation) do
    attrs = %{
      account_id: mutation.account_id,
      inventory_item_id: state.item.id,
      trigger_type: mutation.trigger_type,
      operation: operation,
      quantity_before_milli: state.before_qty,
      quantity_delta_milli: state.delta,
      quantity_after_milli: state.after_qty,
      source_checkout_session_id: mutation.source_checkout_session_id,
      source_cooking_session_id: mutation.source_cooking_session_id,
      source_user_id: mutation.source_user_id,
      raw_voice_text: mutation.raw_voice_text,
      metadata: mutation.metadata
    }

    %InventoryMutationEvent{}
    |> InventoryMutationEvent.changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, event} -> event
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp normalize_mutation(opts) do
    operation = value(opts, :operation)

    has_target =
      Map.has_key?(opts, :target_quantity_milli) or Map.has_key?(opts, "target_quantity_milli")

    %{
      account_id: value(opts, :account_id),
      source_user_id: value(opts, :source_user_id),
      item_id: value(opts, :inventory_item_id) || value(opts, :item_id),
      ingredient_id: value(opts, :ingredient_id),
      unit: normalize_unit(value(opts, :unit)),
      source_kind: normalize_source_kind(value(opts, :source_kind)),
      trigger_type: normalize_trigger_type(value(opts, :trigger_type)),
      operation: operation,
      set?: operation in [:set, "set"] or has_target,
      delete?: operation in [:delete, "delete"],
      target_qty: value(opts, :target_quantity_milli),
      delta: value(opts, :delta) || 0,
      metadata: value(opts, :metadata) || %{},
      raw_voice_text: value(opts, :raw_voice_text),
      source_checkout_session_id: value(opts, :source_checkout_session_id),
      source_cooking_session_id: value(opts, :source_cooking_session_id),
      lot_metadata: Map.new(@lot_fields, &{&1, value(opts, &1)})
    }
  end

  defp event_operation(%{delete?: true}, _delta), do: :delete
  defp event_operation(%{set?: true}, _delta), do: :set
  defp event_operation(%{operation: operation}, _delta) when operation in [:add, "add"], do: :add

  defp event_operation(%{operation: operation}, _delta)
       when operation in [:subtract, "subtract"],
       do: :subtract

  defp event_operation(_mutation, delta) when delta >= 0, do: :add
  defp event_operation(_mutation, _delta), do: :subtract

  defp result(state, event) do
    %{
      item_state: state,
      mutation_event: event,
      item: state.item,
      before_qty: state.before_qty,
      after_qty: state.after_qty,
      delta: state.delta
    }
  end

  defp empty_result do
    %{
      item_states: [],
      mutation_events: [],
      item: nil,
      mutation_event: nil,
      before_qty: 0,
      after_qty: 0,
      delta: 0
    }
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp state_item(nil), do: nil
  defp state_item(state), do: state.item

  defp preload_item(nil, _repo), do: nil
  defp preload_item(item, repo), do: repo.preload(item, [:ingredient])

  defp metadata_bearing?(metadata),
    do: Enum.any?(@lot_fields, &(not is_nil(Map.get(metadata, &1))))

  defp has_quantity?(attrs),
    do: Map.has_key?(attrs, :quantity_milli) or Map.has_key?(attrs, "quantity_milli")

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_unit(nil), do: :g
  defp normalize_unit(value) when value in [:g, "g", :grams, "grams"], do: :g
  defp normalize_unit(value) when value in [:ml, "ml"], do: :ml
  defp normalize_unit(value) when value in [:unit, "unit", :units, "units"], do: :unit
  defp normalize_unit(_), do: :g

  defp normalize_source_kind(value) when value in [:extra, "extra"], do: :extra
  defp normalize_source_kind(_), do: :planned

  defp normalize_trigger_type(value) when value in [:purchase, "purchase"], do: :purchase
  defp normalize_trigger_type(value) when value in [:cooking, "cooking"], do: :cooking
  defp normalize_trigger_type(value) when value in [:voice, "voice"], do: :voice
  defp normalize_trigger_type(_), do: :manual
end
