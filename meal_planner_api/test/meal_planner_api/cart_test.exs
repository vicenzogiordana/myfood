defmodule MealPlannerApi.CartTest do
  use ExUnit.Case, async: false
  import MealPlannerApi.CartFixtures
  alias MealPlannerApi.{Cart, Repo, ShoppingCheckout}
  alias MealPlannerApi.Persistence.Shopping.CheckoutSession
  alias MealPlannerApi.Services.ShoppingService

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    {:ok, fixture()}
  end

  test "member-owned reservations are visible to peers but cannot be taken or purchased by them",
       f do
    cart = reserve!(f)
    assert cart.owner_user_id == f.owner.id
    assert DateTime.diff(cart.lease_expires_at, DateTime.utc_now()) in 3599..3600
    assert {:ok, view} = ShoppingService.get_shopping_list(f.other)
    assert length(hd(view.items).lines) == 2
    assert Enum.all?(hd(view.items).lines, &(&1.reserved_by_user_id == f.owner.id))
    assert {:error, :already_reserved} = Cart.reserve(f.other, [hd(f.items).id])
    assert {:error, :cart_not_found} = Cart.purchase(f.other, cart.session_id, payload(cart))
    assert {:error, :cart_not_found} = Cart.cancel(f.other, cart.session_id)
    assert {:error, :cart_not_found} = Cart.renew(f.other, cart.session_id)
    assert stock(f) == []
  end

  test "activity renews the whole cart and read-only viewing does not", f do
    cart = reserve!(f)
    old = DateTime.add(DateTime.utc_now(), 120)

    Repo.get!(CheckoutSession, cart.session_id)
    |> CheckoutSession.changeset(%{lease_expires_at: old})
    |> Repo.update!()

    assert {:ok, _} = ShoppingService.get_shopping_list(f.other)
    assert Repo.get!(CheckoutSession, cart.session_id).lease_expires_at == old
    assert {:ok, renewed} = Cart.renew(f.actor, cart.session_id)
    assert DateTime.diff(renewed.lease_expires_at, DateTime.utc_now()) in 3599..3600
    assert {:ok, 0} = Cart.expire_account(f.account.id, DateTime.add(old, 1))
    assert Enum.all?(lines(f), &(&1.status == :in_cart))
  end

  test "removal releases atomically; old tokens cannot act on a new reservation in the same cart",
       f do
    cart = reserve!(f)
    [line | _] = payload(cart)["items"]

    assert {:error, :stale_reservation} =
             Cart.remove(f.actor, cart.session_id, [
               Map.put(line, "reservation_token", Ecto.UUID.generate())
             ])

    assert Enum.all?(lines(f), &(&1.status == :in_cart))
    assert {:ok, %{updated_rows: 1}} = Cart.remove(f.actor, cart.session_id, [line])
    assert {:ok, renewed} = Cart.reserve(f.actor, [line["item_id"]])
    refute hd(renewed.reservations).reservation_token == line["reservation_token"]
    assert {:error, :stale_reservation} = Cart.remove(f.actor, cart.session_id, [line])
    assert {:error, :stale_reservation} = Cart.purchase(f.actor, cart.session_id, payload(cart))
  end

  test "cancellation releases every line and rejects stale confirmation", f do
    cart = reserve!(f)
    assert {:ok, %{updated_rows: 2}} = Cart.cancel(f.actor, cart.session_id)
    assert Enum.all?(lines(f), &(&1.status == :pending and is_nil(&1.reservation_token)))
    assert {:error, :stale_cart} = Cart.purchase(f.actor, cart.session_id, payload(cart))
    assert {:ok, _} = Cart.reserve(f.other, Enum.map(f.items, & &1.id))
    assert events(f) == []
  end

  test "expired cart releases even when a stale purchase fails, without renewing stale authority",
       f do
    cart = reserve!(f)
    expire!(cart)
    assert {:error, :stale_cart} = Cart.purchase(f.actor, cart.session_id, payload(cart))
    assert {:error, :stale_cart} = Cart.renew(f.actor, cart.session_id)
    assert Enum.all?(lines(f), &(&1.status == :pending and is_nil(&1.checkout_session_id)))
    assert Repo.get!(CheckoutSession, cart.session_id).status == :abandoned
    next = reserve!(f, f.other)
    refute next.session_id == cart.session_id
  end

  test "automatic sweeper releases abandoned reservations without a read or command", f do
    cart = reserve!(f)
    expire!(cart)
    sweeper = start_supervised!({MealPlannerApi.CartSweeper, name: nil, interval: 600_000})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), sweeper)
    Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "shopping:#{f.account.id}")
    send(sweeper, :tick)
    _ = :sys.get_state(sweeper)
    assert_receive %Phoenix.Socket.Broadcast{event: "cart_expired"}
    assert Enum.all?(lines(f), &(&1.status == :pending))
    send(sweeper, :tick)
    _ = :sys.get_state(sweeper)
    refute_receive %Phoenix.Socket.Broadcast{event: "cart_expired"}
  end

  for type <- ["physical", "online"] do
    test "#{type} actual purchase atomically records lots, spend, movements and available remainder",
         f do
      cart = reserve!(f)
      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "shopping:#{f.account.id}")

      assert {:ok, %{actual_total_cents: 500}} =
               ShoppingCheckout.confirm_checkout(f.actor, payload(cart, 300, unquote(type)))

      assert_receive %Phoenix.Socket.Broadcast{event: "purchase_confirmed"}
      assert_receive %Phoenix.Socket.Broadcast{event: "inventory_changed"}
      assert Enum.sum(Enum.map(stock(f), & &1.quantity_milli)) == 600
      assert Enum.sum(Enum.map(stock(f), & &1.acquired_price_cents)) == 500
      assert length(stock(f)) == 2
      assert length(events(f)) == 2

      assert Enum.all?(
               events(f),
               &(&1.source_checkout_session_id == cart.session_id and
                   &1.source_user_id == f.owner.id and &1.quantity_delta_milli == 300)
             )

      remaining = Enum.filter(lines(f), &(&1.status == :pending))
      assert Enum.sort(Enum.map(remaining, & &1.quantity_milli)) == [200, 700]

      assert Enum.all?(
               remaining,
               &(is_nil(&1.checkout_session_id) and is_nil(&1.reservation_token))
             )

      snapshot = {stock(f), events(f), lines(f), Repo.get!(CheckoutSession, cart.session_id)}

      assert {:error, :already_purchased} =
               ShoppingCheckout.confirm_checkout(f.actor, payload(cart))

      assert {:ok, %{"moved_to_inventory_count" => 0}} =
               ShoppingService.confirm_delivery(f.actor, cart.session_id)

      assert {stock(f), events(f), lines(f), Repo.get!(CheckoutSession, cart.session_id)} ==
               snapshot

      refute_receive %Phoenix.Socket.Broadcast{event: "purchase_confirmed"}
      refute_receive %Phoenix.Socket.Broadcast{event: "inventory_changed"}
      assert {:ok, view} = ShoppingService.get_shopping_list(f.other)
      assert hd(view.items).total_quantity_milli == 900
    end
  end

  test "zero purchased quantity returns the line and creates no stock or spend", f do
    cart = reserve!(f)

    assert {:ok, %{actual_total_cents: 0, moved_to_inventory_count: 0}} =
             Cart.purchase(f.actor, cart.session_id, payload(cart, 0))

    assert stock(f) == []
    assert events(f) == []
    assert Enum.all?(lines(f), &(&1.status == :pending))
  end

  test "actual quantity above the reservation adds exactly what was bought without a negative remainder",
       f do
    cart = reserve!(f)
    assert {:ok, _} = Cart.purchase(f.actor, cart.session_id, payload(cart, 1200))
    assert Enum.sum(Enum.map(stock(f), & &1.quantity_milli)) == 2400
    assert Enum.all?(lines(f), &(&1.status == :checked_out and &1.quantity_milli == 1200))
  end

  test "invalid, missing, duplicate and incomplete purchase data leave all rows untouched", f do
    cart = reserve!(f)
    original = lines(f)
    data = payload(cart)
    [line | _] = data["items"]

    for {items, reason} <- [
          {[], :invalid_purchase_items},
          {[line], :incomplete_cart},
          {[line, line], :duplicate_item},
          {[Map.put(line, "item_id", nil)], :invalid_payload},
          {Enum.map(data["items"], &Map.put(&1, "quantity_milli", -1)), :invalid_quantity},
          {Enum.map(data["items"], &Map.put(&1, "total_cents", -1)), :invalid_price}
        ] do
      assert {:error, ^reason} =
               Cart.purchase(f.actor, cart.session_id, Map.put(data, "items", items))

      assert lines(f) == original
      assert stock(f) == []
      assert events(f) == []
    end

    assert {:error, :invalid_payload} = ShoppingCheckout.confirm_checkout(f.actor, %{})

    assert {:error, :reservation_required} =
             ShoppingService.create_checkout_from_range(
               f.actor,
               Date.utc_today(),
               Date.utc_today(),
               "physical"
             )
  end

  test "foreign Account and revoked membership cannot reserve or purchase", f do
    foreign = fixture()
    cart = reserve!(f)
    assert {:error, :item_not_found} = Cart.reserve(foreign.actor, Enum.map(f.items, & &1.id))

    assert {:error, :cart_not_found} =
             Cart.purchase(foreign.actor, cart.session_id, payload(cart))

    membership =
      Repo.get_by!(MealPlannerApi.Persistence.Accounts.AccountMembership,
        account_id: f.account.id,
        user_id: f.owner.id
      )

    membership |> Ecto.Changeset.change(status: :suspended) |> Repo.update!()
    assert {:error, _} = Cart.purchase(f.actor, cart.session_id, payload(cart))
    assert stock(f) == []
  end
end
