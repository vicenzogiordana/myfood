defmodule MealPlannerApi.Cart do
  @moduledoc "Account-scoped cart leases and the single atomic purchase authority."
  import Ecto.Query
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.{Identity, Inventory, Shopping}
  alias MealPlannerApi.Persistence.Shopping.{CheckoutSession, ShoppingItem}
  alias MealPlannerApi.Services.PlanningRequestValidator

  @lease_seconds 3600

  def reserve(user, item_ids) when is_list(item_ids) and item_ids != [] do
    with {:ok, ids} <- identity(user) do
      transact(ids, "cart_reserved", fn now ->
        require!(Enum.all?(item_ids, &valid_id?/1), :invalid_payload)
        cart = active_cart(ids, now)
        items = lock_items(ids.account_id, item_ids)
        require!(length(items) == length(Enum.uniq(item_ids)), :item_not_found)

        Enum.each(items, fn item ->
          require!(
            item.status == :pending or
              (item.status == :in_cart and item.checkout_session_id == cart.id),
            :already_reserved
          )
        end)

        reserved =
          Enum.map(items, fn item ->
            update!(item, %{
              status: :in_cart,
              checkout_session_id: cart.id,
              reservation_token: item.reservation_token || Ecto.UUID.generate()
            })
          end)

        cart = renew!(cart, now)

        %{
          session_id: cart.id,
          status: "in_cart",
          updated_rows: length(items),
          owner_user_id: ids.user_id,
          lease_expires_at: cart.lease_expires_at,
          reservations: Enum.map(reserved, &reservation/1)
        }
      end)
    end
  end

  def reserve(_, _), do: {:error, :invalid_payload}

  def reserve_ingredient(user, ingredient_id, from_date, to_date) do
    with {:ok, ids} <- identity(user) do
      item_ids =
        Repo.all(
          from(i in ShoppingItem,
            where:
              i.account_id == ^ids.account_id and i.ingredient_id == ^ingredient_id and
                i.planned_date >= ^from_date and i.planned_date <= ^to_date and
                i.status in [:pending, :in_cart],
            select: i.id
          )
        )

      reserve(user, item_ids)
    end
  end

  def remove(user, session_id, reservations) when is_list(reservations) and reservations != [] do
    with {:ok, ids} <- identity(user) do
      transact(ids, "cart_released", fn now ->
        cart = owned_cart!(ids, session_id, now)
        items = validate_lines!(ids, cart, reservations)
        Enum.each(items, fn {item, _line} -> release!(item) end)
        renew!(cart, now)
        %{session_id: cart.id, updated_rows: length(items), status: "pending"}
      end)
    end
  end

  def remove(_, _, _), do: {:error, :invalid_payload}

  def renew(user, session_id) do
    with {:ok, ids} <- identity(user) do
      transact(ids, "cart_renewed", fn now ->
        cart = owned_cart!(ids, session_id, now) |> renew!(now)
        %{session_id: cart.id, lease_expires_at: cart.lease_expires_at}
      end)
    end
  end

  def cancel(user, session_id) do
    with {:ok, ids} <- identity(user) do
      transact(ids, "cart_released", fn now ->
        cart = owned_cart!(ids, session_id, now)
        count = release_cart!(cart, now)
        %{session_id: cart.id, updated_rows: count, status: "abandoned"}
      end)
    end
  end

  # Both online and physical purchase confirmations add the actual purchase now.
  # Delivery acknowledgement is not another inventory mutation (#29).
  def purchase(user, session_id, payload) when is_map(payload) do
    with {:ok, ids} <- identity(user) do
      transact(ids, "purchase_confirmed", fn now ->
        cart = get_owned!(ids, session_id)
        require!(cart.status != :completed, :already_purchased)
        require_active!(cart, now)
        type = payload["checkout_type"]
        require!(type in ["physical", "online"], :invalid_checkout_type)
        lines = payload["items"]
        require!(is_list(lines) and lines != [], :invalid_purchase_items)
        pairs = validate_lines!(ids, cart, lines)
        current = cart_items(cart)
        require!(length(pairs) == length(current), :incomplete_cart)

        Enum.each(pairs, fn {_item, line} ->
          require!(
            is_integer(line["quantity_milli"]) and line["quantity_milli"] >= 0,
            :invalid_quantity
          )

          require!(
            is_integer(line["total_cents"]) and line["total_cents"] >= 0,
            :invalid_price
          )

          require!(line["quantity_milli"] > 0 or line["total_cents"] == 0, :invalid_price)
        end)

        # Match inventory's canonical lock order across multi-ingredient purchases.
        pairs = Enum.sort_by(pairs, fn {item, _} -> {item.ingredient_id, item.unit, item.id} end)
        Enum.each(pairs, fn {item, line} -> purchase_line!(ids, cart, item, line, now) end)
        moved = Enum.count(pairs, fn {_, line} -> line["quantity_milli"] > 0 end)
        total = Enum.sum(Enum.map(pairs, fn {_, line} -> line["total_cents"] end))

        result = %{
          checkout_session_id: cart.id,
          status: "completed",
          checkout_type: type,
          moved_to_inventory_count: moved,
          checked_out_items_count: moved,
          actual_total_cents: total
        }

        update!(cart, %{
          status: :completed,
          checkout_type: type,
          total_cents: total,
          confirmed_by_user_id: ids.user_id,
          confirmed_at: now,
          purchase_result: result
        })

        result
      end)
    end
  end

  def purchase(_, _, _), do: {:error, :invalid_payload}

  def delivery(user, session_id) do
    with {:ok, ids} <- identity(user) do
      case Shopping.get_checkout_session_for_account(ids.account_id, session_id) do
        %CheckoutSession{status: :completed, purchase_result: result} when is_map(result) ->
          {:ok, Map.put(result, "moved_to_inventory_count", 0)}

        _ ->
          {:error, :invalid_checkout_status}
      end
    end
  end

  def expire_account(account_id, now \\ DateTime.utc_now()) do
    result =
      Repo.transaction(fn ->
        lock_account!(account_id)
        expire_locked(account_id, now)
      end)

    case result do
      {:ok, sessions} ->
        Enum.each(sessions, &notify(account_id, "cart_expired", %{session_id: &1}))
        {:ok, length(sessions)}

      error ->
        error
    end
  end

  def expire_due do
    now = DateTime.utc_now()

    Repo.all(
      from(c in CheckoutSession,
        where:
          c.status == :draft and not is_nil(c.reserved_by_user_id) and c.lease_expires_at <= ^now,
        distinct: true,
        select: c.account_id
      )
    )
    |> Enum.each(&expire_account(&1, now))
  end

  def notify(account_id, event, payload) do
    if not MealPlannerApiWeb.ChannelCapability.enforcement_enabled?() or
         MealPlannerApi.AccountAccess.eligible?(account_id) do
      Phoenix.Channel.Server.broadcast!(
        MealPlannerApi.PubSub,
        "shopping:#{account_id}",
        event,
        payload
      )
    end

    :ok
  end

  defp identity(user) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(user),
         :ok <- PlanningRequestValidator.validate_actor(ids.account_id, ids.user_id) do
      if MealPlannerApiWeb.ChannelCapability.enforcement_enabled?() and
           not MealPlannerApi.AccountAccess.eligible?(ids.account_id),
         do: {:error, :subscription_required},
         else: {:ok, ids}
    end
  end

  defp transact(ids, event, fun) do
    # Expiry commits independently: a rejected stale command must not resurrect a lease.
    with {:ok, _} <- expire_account(ids.account_id) do
      result =
        Repo.transaction(fn ->
          lock_account!(ids.account_id)

          case identity(%{id: ids.user_id, account_id: ids.account_id}) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          fun.(DateTime.utc_now())
        end)

      case result do
        {:ok, response} ->
          notify(ids.account_id, event, response)

          if event == "purchase_confirmed" and response.moved_to_inventory_count > 0,
            do: notify(ids.account_id, "inventory_changed", %{refresh: true})

        _ ->
          :ok
      end

      result
    end
  rescue
    Ecto.Query.CastError -> {:error, :invalid_payload}
  end

  defp lock_account!(account_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["cart:#{account_id}"])
  end

  defp active_cart(ids, now) do
    cart =
      Repo.one(
        from(c in CheckoutSession,
          where:
            c.account_id == ^ids.account_id and
              c.reserved_by_user_id == ^ids.user_id and c.status == :draft,
          lock: "FOR UPDATE"
        )
      ) ||
        insert!(
          CheckoutSession.changeset(%CheckoutSession{}, %{
            account_id: ids.account_id,
            reserved_by_user_id: ids.user_id,
            status: :draft,
            checkout_type: :physical,
            lease_expires_at: DateTime.add(now, @lease_seconds, :second)
          })
        )

    require_active!(cart, now)
    cart
  end

  defp get_owned!(ids, session_id) do
    require!(valid_id?(session_id), :invalid_payload)

    cart =
      Repo.one(
        from(c in CheckoutSession,
          where:
            c.account_id == ^ids.account_id and
              c.id == ^session_id and c.reserved_by_user_id == ^ids.user_id,
          lock: "FOR UPDATE"
        )
      )

    require!(not is_nil(cart), :cart_not_found)
    cart
  end

  defp owned_cart!(ids, session_id, now) do
    cart = get_owned!(ids, session_id)
    require_active!(cart, now)
    cart
  end

  defp require_active!(cart, now) do
    require!(
      cart.status == :draft and not is_nil(cart.lease_expires_at) and
        DateTime.compare(cart.lease_expires_at, now) == :gt,
      :stale_cart
    )
  end

  defp renew!(cart, now),
    do: update!(cart, %{lease_expires_at: DateTime.add(now, @lease_seconds, :second)})

  defp expire_locked(account_id, now) do
    Repo.all(
      from(c in CheckoutSession,
        where:
          c.account_id == ^account_id and c.status == :draft and
            not is_nil(c.reserved_by_user_id) and c.lease_expires_at <= ^now,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.map(fn cart ->
      release_cart!(cart, now)
      cart.id
    end)
  end

  defp release_cart!(cart, now) do
    items = cart_items(cart)
    Enum.each(items, &release!/1)
    update!(cart, %{status: :abandoned, invalidated_at: now})
    length(items)
  end

  defp release!(item),
    do: update!(item, %{status: :pending, checkout_session_id: nil, reservation_token: nil})

  defp cart_items(cart) do
    Repo.all(
      from(i in ShoppingItem,
        where:
          i.account_id == ^cart.account_id and
            i.checkout_session_id == ^cart.id and i.status == :in_cart,
        order_by: i.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_items(account_id, item_ids) do
    Repo.all(
      from(i in ShoppingItem,
        where: i.account_id == ^account_id and i.id in ^item_ids,
        order_by: i.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp validate_lines!(ids, cart, lines) do
    require!(Enum.all?(lines, &is_map/1), :invalid_payload)
    item_ids = Enum.map(lines, & &1["item_id"])
    require!(Enum.all?(item_ids, &valid_id?/1), :invalid_payload)
    require!(length(item_ids) == length(Enum.uniq(item_ids)), :duplicate_item)
    items = lock_items(ids.account_id, item_ids)
    require!(length(items) == length(lines), :item_not_found)

    Enum.map(items, fn item ->
      line = Enum.find(lines, &(&1["item_id"] == item.id))

      require!(
        item.status == :in_cart and item.checkout_session_id == cart.id and
          not is_nil(item.reservation_token) and
          item.reservation_token == line["reservation_token"],
        :stale_reservation
      )

      {item, line}
    end)
  end

  defp purchase_line!(ids, cart, item, line, now) do
    quantity = line["quantity_milli"]

    if quantity == 0 do
      release!(item)
    else
      case Inventory.apply_delta_and_log(%{
             account_id: ids.account_id,
             ingredient_id: item.ingredient_id,
             unit: item.unit,
             source_kind: :planned,
             delta: quantity,
             source_user_id: ids.user_id,
             trigger_type: :purchase,
             operation: :add,
             acquired_at: now,
             acquired_price_cents: line["total_cents"],
             source_checkout_session_id: cart.id,
             metadata: %{shopping_item_id: item.id}
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      if quantity < item.quantity_milli do
        item
        |> Map.from_struct()
        |> Map.take([
          :account_id,
          :scheduled_meal_id,
          :planned_date,
          :ingredient_id,
          :unit,
          :assigned_supermarket_id
        ])
        |> Map.merge(%{quantity_milli: item.quantity_milli - quantity, status: :pending})
        |> then(&ShoppingItem.changeset(%ShoppingItem{}, &1))
        |> insert!()
      end

      update!(item, %{
        status: :checked_out,
        quantity_milli: quantity,
        estimated_price_cents: line["total_cents"]
      })
    end
  end

  defp reservation(item),
    do: %{
      item_id: item.id,
      reservation_token: item.reservation_token,
      quantity_milli: item.quantity_milli
    }

  defp require!(true, _), do: :ok
  defp require!(_, reason), do: Repo.rollback(reason)

  defp valid_id?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  defp update!(%CheckoutSession{} = item, attrs),
    do: item |> CheckoutSession.changeset(attrs) |> persist!(:update)

  defp update!(%ShoppingItem{} = item, attrs),
    do: item |> ShoppingItem.changeset(attrs) |> persist!(:update)

  defp insert!(changeset), do: persist!(changeset, :insert)

  defp persist!(changeset, operation) do
    case apply(Repo, operation, [changeset]) do
      {:ok, row} -> row
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
