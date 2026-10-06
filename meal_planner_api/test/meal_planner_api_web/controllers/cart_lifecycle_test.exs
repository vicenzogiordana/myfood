defmodule MealPlannerApiWeb.CartLifecycleTest do
  use MealPlannerApiWeb.ConnCase, async: false
  import Phoenix.ConnTest, except: [connect: 2, connect: 3]
  import Phoenix.ChannelTest
  import MealPlannerApi.CartFixtures
  import MealPlannerApi.FactoryHelpers
  alias MealPlannerApi.{Cart, Repo}
  alias MealPlannerApi.Persistence.Accounts.{Account, AccountMembership}
  alias MealPlannerApiWeb.{ShoppingChannel, UserSocket}

  setup do
    f = fixture()
    old = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)
    Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)
    on_exit(fn -> Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, old) end)
    {:ok, Map.put(f, :token, token(f.owner, f.account))}
  end

  test "authenticated HTTP lifecycle publishes account-scoped reservation, release, expiry, purchase and inventory changes",
       f do
    {:ok, socket} = connect(UserSocket, %{"token" => token(f.member, f.account)})
    {:ok, _, _socket} = subscribe_and_join(socket, ShoppingChannel, "shopping:#{f.account.id}")
    foreign = fixture()
    {:ok, other_socket} = connect(UserSocket, %{"token" => token(foreign.owner, foreign.account)})

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(other_socket, ShoppingChannel, "shopping:#{f.account.id}")

    cart =
      request(f, :post, "/api/shopping-items/mark-cart", %{
        "item_ids" => Enum.map(f.items, & &1.id)
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert_push "cart_reserved", %{owner_user_id: owner_id}
    assert owner_id == f.owner.id
    id = cart["session_id"]

    assert %{"data" => _} =
             request(f, :post, "/api/cart/#{id}/activity", %{}) |> json_response(200)

    assert_push "cart_renewed", _
    [line | _] = cart["reservations"]

    assert %{"data" => _} =
             request(f, :post, "/api/shopping-items/mark-cart", %{
               "in_cart" => false,
               "session_id" => id,
               "items" => [line]
             })
             |> json_response(200)

    assert_push "cart_released", _
    assert %{"data" => _} = request(f, :delete, "/api/cart/#{id}", %{}) |> json_response(200)
    assert_push "cart_released", _

    current = reserve!(f)
    assert_push "cart_reserved", _
    expire!(current)
    assert {:ok, 1} = Cart.expire_account(f.account.id)
    assert_push "cart_expired", _
    current = reserve!(f)
    assert_push "cart_reserved", _

    assert %{"data" => %{"actual_total_cents" => 500}} =
             request(f, :post, "/api/checkout/confirm", payload(current)) |> json_response(200)

    assert_push "purchase_confirmed", _
    assert_push "inventory_changed", _

    assert %{"error" => "already_purchased"} =
             request(f, :post, "/api/checkout/confirm", payload(current)) |> json_response(422)

    refute_push "purchase_confirmed", _
    refute_push "inventory_changed", _

    lot = hd(stock(f))

    assert %{"data" => _} =
             request(f, :post, "/api/inventory/items/#{lot.id}/quantity", %{
               "quantity_milli" => 450
             })
             |> json_response(200)

    assert_push "inventory_changed", _
    assert length(events(f)) == 3
    # A foreign topic must not reach the subscribed member.
    Cart.notify(foreign.account.id, "cart_reserved", %{session_id: "foreign"})
    refute_push "cart_reserved", _
  end

  test "expired Account cannot reserve, buy, renew, cancel, or adjust and cannot receive realtime events",
       f do
    cart = reserve!(f)
    {:ok, socket} = connect(UserSocket, %{"token" => f.token})
    {:ok, _, joined} = subscribe_and_join(socket, ShoppingChannel, "shopping:#{f.account.id}")
    snapshot = {lines(f), stock(f), events(f)}
    expire_account!(f.account)

    for {method, path, data} <- [
          {:post, "/api/shopping-items/mark-cart", %{"item_ids" => Enum.map(f.items, & &1.id)}},
          {:post, "/api/checkout/confirm", payload(cart)},
          {:post, "/api/cart/#{cart.session_id}/activity", %{}},
          {:delete, "/api/cart/#{cart.session_id}", %{}},
          {:post, "/api/inventory/items/add-extra",
           %{"ingredient_id" => f.ingredient.id, "quantity_milli" => 100, "unit" => "g"}},
          {:post, "/api/inventory/items/#{Ecto.UUID.generate()}/quantity",
           %{"quantity_milli" => 10}}
        ] do
      assert %{"error" => "subscription_required"} =
               request(f, method, path, data) |> json_response(403)
    end

    assert {lines(f), stock(f), events(f)} == snapshot

    assert {:error, :subscription_required} =
             Cart.purchase(f.actor, cart.session_id, payload(cart))

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, ShoppingChannel, "shopping:#{f.account.id}")

    # Exercise recipient-side authorization even if a producer bypasses its eligibility check.
    Phoenix.Channel.Server.broadcast!(MealPlannerApi.PubSub, joined.topic, "inventory_changed", %{
      refresh: true
    })

    _ = :sys.get_state(joined.channel_pid)
    refute_push "inventory_changed", _
  end

  test "same-account member reads ownership; foreign Account cannot mutate cart or inventory",
       f do
    cart = reserve!(f)
    other = %{f | token: token(f.member, f.account)}
    view = request(other, :get, "/api/shopping-list", %{}) |> json_response(200)

    assert Enum.all?(
             hd(view["data"]["items"])["lines"],
             &(&1["reserved_by_user_id"] == f.owner.id)
           )

    assert %{"error" => "cart_not_found"} =
             request(other, :post, "/api/checkout/confirm", payload(cart)) |> json_response(422)

    assert %{"data" => _} =
             request(f, :post, "/api/checkout/confirm", payload(cart)) |> json_response(200)

    foreign = fixture()
    foreign = Map.put(foreign, :token, token(foreign.owner, foreign.account))
    lot = hd(stock(f))
    snapshot = {stock(f), events(f)}

    assert %{"error" => "item_not_found"} =
             request(foreign, :post, "/api/inventory/items/#{lot.id}/quantity", %{
               "quantity_milli" => 999
             })
             |> json_response(422)

    assert {stock(f), events(f)} == snapshot

    assert %{"error" => "cart_not_found"} =
             request(foreign, :post, "/api/checkout/confirm", payload(cart)) |> json_response(422)
  end

  test "suspended member receives no subsequent events", f do
    member_token = token(f.member, f.account)
    {:ok, socket} = connect(UserSocket, %{"token" => member_token})
    {:ok, _, joined} = subscribe_and_join(socket, ShoppingChannel, "shopping:#{f.account.id}")
    membership = Repo.get_by!(AccountMembership, user_id: f.member.id, account_id: f.account.id)
    membership |> AccountMembership.changeset(%{status: :suspended}) |> Repo.update!()
    Cart.notify(f.account.id, "cart_reserved", %{session_id: "hidden"})
    _ = :sys.get_state(joined.channel_pid)
    refute_push "cart_reserved", _
  end

  defp token(user, account) do
    membership = Repo.get_by!(AccountMembership, user_id: user.id, account_id: account.id)
    issue_access_v2_token(user, Repo.preload(membership, :account))
  end

  defp request(f, method, path, params) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> f.token)
    dispatch(conn, @endpoint, method, path, params)
  end

  defp expire_account!(account) do
    past = DateTime.add(DateTime.utc_now(), -86400)
    account |> Account.changeset(%{trial_started_at: past, trial_ends_at: past}) |> Repo.update!()
  end
end
