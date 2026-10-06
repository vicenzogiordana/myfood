defmodule MealPlannerApi.InventoryTest do
  use ExUnit.Case, async: false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Inventory
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Inventory, as: PersistenceInventory
  alias MealPlannerApi.Persistence.Inventory.InventoryItem
  alias MealPlannerApi.Persistence.Inventory.InventoryMutationEvent
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  test "available_for subtracts future reservations and releases past uncooked meals" do
    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "u_inv_reserved",
        "account_id" => "acct_inv_reserved",
        "account_type" => "group",
        "subscription_tier" => "premium"
      })

    {:ok, %{user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: user.id,
        account_id: account.id,
        plan: :family_4
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Pollo Reserva Test",
        category: :carnes,
        calories_per_100: 239,
        protein_g_per_100: Decimal.new("27.0"),
        carbs_g_per_100: Decimal.new("0.0"),
        fat_g_per_100: Decimal.new("14.0")
      })

    {:ok, recipe_future} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Pollo mañana",
        source: :user_created,
        servings: 1,
        suitable_for_slots: [:lunch]
      })

    {:ok, _ri_future} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe_future.id,
        ingredient_id: ingredient.id,
        quantity_milli: 300,
        unit: :g
      })

    {:ok, recipe_past} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Pollo ayer",
        source: :user_created,
        servings: 1,
        suitable_for_slots: [:dinner]
      })

    {:ok, _ri_past} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe_past.id,
        ingredient_id: ingredient.id,
        quantity_milli: 200,
        unit: :g
      })

    tomorrow = Date.add(Date.utc_today(), 1)
    yesterday = Date.add(Date.utc_today(), -1)

    {:ok, _meal_future} =
      Planning.schedule_meal(%{
        account_id: account.id,
        date: tomorrow,
        slot: :lunch,
        recipe_id: recipe_future.id,
        is_cooked: false
      })

    {:ok, _meal_past} =
      Planning.schedule_meal(%{
        account_id: account.id,
        date: yesterday,
        slot: :dinner,
        recipe_id: recipe_past.id,
        is_cooked: false
      })

    {:ok, _inventory_item} =
      PersistenceInventory.apply_delta_and_log(%{
        account_id: account.id,
        ingredient_id: ingredient.id,
        unit: :g,
        source_kind: :planned,
        delta: 500,
        source_user_id: user_id,
        trigger_type: :purchase,
        operation: :add
      })

    available = Inventory.available_for(%{id: user.id, account_id: account.id}, %{})

    chicken_available =
      Enum.find(available, fn item -> item.ingredient_id == ingredient.id and item.unit == :g end)

    assert chicken_available.quantity_milli == 200
  end

  test "available_for excludes future reservations inside the requested range" do
    tomorrow = Date.add(Date.utc_today(), 1)

    %{user: user, ingredient: ingredient} =
      inventory_scenario(500, [{tomorrow, 300}])

    available = Inventory.available_for(user, %{exclude_range: {tomorrow, tomorrow}})

    assert [%{ingredient_id: ingredient_id, unit: :g, quantity_milli: 500}] = available
    assert ingredient_id == ingredient.id
  end

  test "available_for preserves future reservations outside the excluded range" do
    tomorrow = Date.add(Date.utc_today(), 1)
    after_window = Date.add(tomorrow, 1)

    %{user: user, ingredient: ingredient} =
      inventory_scenario(1_000, [{tomorrow, 300}, {after_window, 200}])

    available = Inventory.available_for(user, %{exclude_range: {tomorrow, tomorrow}})

    assert [%{ingredient_id: ingredient_id, unit: :g, quantity_milli: 800}] = available
    assert ingredient_id == ingredient.id
  end

  defp inventory_scenario(stock_quantity, reservations) do
    suffix = System.unique_integer([:positive])

    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "u_inv_range_#{suffix}",
        "account_id" => "acct_inv_range_#{suffix}",
        "account_type" => "group",
        "subscription_tier" => "premium"
      })

    {:ok, %{user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: user.id,
        account_id: account.id,
        plan: :family_4
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Range reservation ingredient #{suffix}",
        category: :carnes,
        calories_per_100: 100,
        protein_g_per_100: Decimal.new("10.0"),
        carbs_g_per_100: Decimal.new("0.0"),
        fat_g_per_100: Decimal.new("5.0")
      })

    Enum.with_index(reservations, fn {date, quantity}, index ->
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Range reservation recipe #{suffix}-#{index}",
          source: :user_created,
          servings: 1,
          suitable_for_slots: [:lunch]
        })

      {:ok, _recipe_ingredient} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: quantity,
          unit: :g
        })

      {:ok, _meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: date,
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })
    end)

    {:ok, _inventory_item} =
      PersistenceInventory.apply_delta_and_log(%{
        account_id: account.id,
        ingredient_id: ingredient.id,
        unit: :g,
        source_kind: :planned,
        delta: stock_quantity,
        source_user_id: user_id,
        trigger_type: :purchase,
        operation: :add
      })

    %{user: %{id: user.id, account_id: account.id}, ingredient: ingredient}
  end

  describe "lot persistence and usable availability" do
    test "metadata-bearing additions remain distinct while anonymous additions share the oldest default lot" do
      %{account: account, ingredient: ingredient, user_id: user_id} = lot_identity("separation")
      acquired_at = DateTime.add(DateTime.utc_now(), -86_400)
      expires_first = DateTime.add(DateTime.utc_now(), 2 * 86_400)
      expires_later = DateTime.add(DateTime.utc_now(), 4 * 86_400)

      for {quantity, expiry, price} <- [{100, expires_first, 500}, {200, expires_later, 700}] do
        assert {:ok, _result} =
                 PersistenceInventory.apply_delta_and_log(%{
                   account_id: account.id,
                   ingredient_id: ingredient.id,
                   unit: :g,
                   source_kind: :planned,
                   delta: quantity,
                   acquired_at: acquired_at,
                   expired_at: expiry,
                   acquired_price_cents: price,
                   source_user_id: user_id,
                   trigger_type: :purchase,
                   operation: :add
                 })
      end

      for quantity <- [30, 40] do
        assert {:ok, _result} =
                 PersistenceInventory.apply_delta_and_log(%{
                   account_id: account.id,
                   ingredient_id: ingredient.id,
                   unit: :g,
                   source_kind: :planned,
                   delta: quantity,
                   source_user_id: user_id,
                   trigger_type: :purchase,
                   operation: :add
                 })
      end

      lots = PersistenceInventory.list_inventory(account.id)
      assert length(lots) == 3
      assert Enum.map(lots, & &1.quantity_milli) |> Enum.sort() == [70, 100, 200]

      assert Enum.count(lots, fn lot ->
               is_nil(lot.acquired_at) and is_nil(lot.expired_at) and
                 is_nil(lot.acquired_price_cents)
             end) == 1

      assert Enum.map(lots, & &1.acquired_price_cents) |> Enum.reject(&is_nil/1) |> Enum.sort() ==
               [500, 700]
    end

    test "availability excludes expired lots and subtraction consumes usable lots in stable FEFO order" do
      %{account: account, ingredient: ingredient, user: user, user_id: user_id} =
        lot_identity("fefo")

      yesterday = DateTime.add(DateTime.utc_now(), -2 * 86_400)
      tomorrow = DateTime.add(DateTime.utc_now(), 2 * 86_400)
      next_week = DateTime.add(DateTime.utc_now(), 7 * 86_400)

      seeded =
        for {quantity, expiry, price} <- [
              {100, yesterday, 100},
              {80, tomorrow, 200},
              {100, next_week, 300}
            ] do
          {:ok, result} =
            PersistenceInventory.apply_delta_and_log(%{
              account_id: account.id,
              ingredient_id: ingredient.id,
              unit: :g,
              source_kind: :planned,
              delta: quantity,
              expired_at: expiry,
              acquired_price_cents: price,
              source_user_id: user_id,
              trigger_type: :purchase,
              operation: :add
            })

          result.item
        end

      assert [%{quantity_milli: 180}] = Inventory.available_for(user)

      assert {:ok, result} =
               PersistenceInventory.subtract_usable_lots_and_log(%{
                 account_id: account.id,
                 ingredient_id: ingredient.id,
                 unit: :g,
                 source_kind: :planned,
                 delta: -120,
                 source_user_id: user_id,
                 trigger_type: :cooking,
                 operation: :subtract
               })

      assert result.delta == -120
      assert Enum.map(result.item_states, & &1.delta) == [-80, -40]

      assert Enum.map(result.mutation_events, & &1.inventory_item_id) ==
               seeded |> Enum.drop(1) |> Enum.map(& &1.id)

      Enum.each(result.mutation_events, fn event ->
        assert event.quantity_before_milli + event.quantity_delta_milli ==
                 event.quantity_after_milli
      end)

      [expired, first_fresh, second_fresh] = Enum.map(seeded, &Repo.reload!/1)
      assert expired.quantity_milli == 100
      assert first_fresh.quantity_milli == 0
      assert second_fresh.quantity_milli == 60
      assert [%{quantity_milli: 60}] = Inventory.available_for(user)
    end

    test "view, availability, and consumption share inferred-expiry boundaries and effective FEFO" do
      %{account: account, ingredient: ingredient, user: user, user_id: user_id} =
        lot_identity("effective-fefo")

      today = Date.utc_today()

      lot_specs = [
        {:explicit_expired, 10, Date.add(today, -1), Date.add(today, -1), 101},
        {:inferred_expired, 20, Date.add(today, -15), nil, 102},
        {:boundary, 30, Date.add(today, -14), nil, 103},
        {:explicit_override, 40, Date.add(today, -30), Date.add(today, 1), 104},
        {:inferred_tomorrow, 50, Date.add(today, -13), nil, 105}
      ]

      lots =
        Map.new(lot_specs, fn {name, quantity, acquired_on, expires_on, price} ->
          {:ok, result} =
            PersistenceInventory.apply_delta_and_log(%{
              account_id: account.id,
              ingredient_id: ingredient.id,
              unit: :g,
              source_kind: :planned,
              delta: quantity,
              acquired_at: noon_utc(acquired_on),
              expired_at: expires_on && noon_utc(expires_on),
              acquired_price_cents: price,
              source_user_id: user_id,
              trigger_type: :purchase,
              operation: :add
            })

          {name, result.item}
        end)

      assert {:ok, view} = MealPlannerApi.Services.InventoryService.inventory_view(user)

      assert view.sections.expired |> Enum.map(& &1.id) |> MapSet.new() ==
               MapSet.new([lots.explicit_expired.id, lots.inferred_expired.id])

      assert view.sections.warning |> Enum.map(& &1.id) |> MapSet.new() ==
               MapSet.new([
                 lots.boundary.id,
                 lots.explicit_override.id,
                 lots.inferred_tomorrow.id
               ])

      assert [%{quantity_milli: 120}] = Inventory.available_for(user)

      assert {:ok, result} =
               PersistenceInventory.subtract_usable_lots_and_log(%{
                 account_id: account.id,
                 ingredient_id: ingredient.id,
                 unit: :g,
                 source_kind: :planned,
                 delta: -45,
                 source_user_id: user_id,
                 trigger_type: :cooking,
                 operation: :subtract
               })

      assert result.delta == -45

      assert Enum.map(result.mutation_events, & &1.inventory_item_id) == [
               lots.boundary.id,
               lots.explicit_override.id
             ]

      assert Repo.reload!(lots.explicit_expired).quantity_milli == 10
      assert Repo.reload!(lots.inferred_expired).quantity_milli == 20
      assert Repo.reload!(lots.boundary).quantity_milli == 0
      assert Repo.reload!(lots.explicit_override).quantity_milli == 25
      assert Repo.reload!(lots.inferred_tomorrow).quantity_milli == 50
      assert [%{quantity_milli: 75}] = Inventory.available_for(user)
    end

    test "clamped by-id subtraction audits the applied delta rather than the request" do
      %{account: account, ingredient: ingredient, user_id: user_id} = lot_identity("clamped")

      {:ok, seeded} =
        PersistenceInventory.apply_delta_and_log(%{
          account_id: account.id,
          ingredient_id: ingredient.id,
          unit: :g,
          source_kind: :planned,
          delta: 100,
          source_user_id: user_id,
          operation: :add
        })

      assert {:ok, result} =
               PersistenceInventory.apply_delta_and_log(%{
                 account_id: account.id,
                 inventory_item_id: seeded.item.id,
                 delta: -150,
                 source_user_id: user_id,
                 operation: :subtract
               })

      assert result.before_qty == 100
      assert result.delta == -100
      assert result.after_qty == 0
      assert result.mutation_event.quantity_delta_milli == -100

      assert result.mutation_event.quantity_before_milli +
               result.mutation_event.quantity_delta_milli ==
               result.mutation_event.quantity_after_milli
    end

    test "absent usable stock creates neither a zero lot nor an event" do
      %{account: account, ingredient: ingredient, user_id: user_id} = lot_identity("absent")

      assert {:ok, %{delta: 0, item_states: [], mutation_events: []}} =
               PersistenceInventory.subtract_usable_lots_and_log(%{
                 account_id: account.id,
                 ingredient_id: ingredient.id,
                 unit: :g,
                 source_kind: :planned,
                 delta: -100,
                 source_user_id: user_id,
                 trigger_type: :cooking,
                 operation: :subtract
               })

      assert PersistenceInventory.list_inventory(account.id) == []

      assert Repo.aggregate(
               from(e in InventoryMutationEvent, where: e.account_id == ^account.id),
               :count
             ) == 0
    end
  end

  describe "PersistenceInventory.apply_delta_and_log/1 — concurrency, isolation, and rollback" do
    test "concurrent initial deltas on non-existent item accumulate into one item without race collisions" do
      suffix = System.unique_integer([:positive])

      {:ok, %{user: user, account: account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_conc_init_#{suffix}",
          "account_id" => "acct_conc_init_#{suffix}",
          "account_type" => "group",
          "subscription_tier" => "premium"
        })

      {:ok, %{user_id: user_id}} =
        Identity.ensure_persistent_identity(%{
          id: user.id,
          account_id: account.id,
          plan: :family_4
        })

      {:ok, ingredient} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Concurrent Initial Ingredient #{suffix}",
          category: :carnes,
          calories_per_100: 200,
          protein_g_per_100: Decimal.new("20.0"),
          carbs_g_per_100: Decimal.new("0.0"),
          fat_g_per_100: Decimal.new("10.0")
        })

      Sandbox.mode(Repo, {:shared, self()})

      deltas = [100, 200, 150, 250, 300]
      expected_total = Enum.sum(deltas)

      tasks =
        Enum.map(deltas, fn delta ->
          Task.async(fn ->
            PersistenceInventory.apply_delta_and_log(%{
              account_id: account.id,
              ingredient_id: ingredient.id,
              unit: :g,
              source_kind: :planned,
              delta: delta,
              source_user_id: user_id,
              trigger_type: :purchase,
              operation: :add
            })
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Exactly one inventory item must exist (no duplicate rows inserted)
      items =
        Repo.all(
          from(i in InventoryItem,
            where: i.account_id == ^account.id and i.ingredient_id == ^ingredient.id
          )
        )

      assert length(items) == 1
      [item] = items
      assert item.quantity_milli == expected_total

      # Exactly 5 mutation events recorded
      events =
        Repo.all(
          from(e in InventoryMutationEvent,
            where: e.inventory_item_id == ^item.id,
            order_by: [asc: e.inserted_at]
          )
        )

      assert length(events) == 5
      assert Enum.sum(Enum.map(events, & &1.quantity_delta_milli)) == expected_total

      Enum.each(events, fn e ->
        assert e.quantity_before_milli + e.quantity_delta_milli == e.quantity_after_milli
        assert e.account_id == account.id
        assert e.source_user_id == user_id
      end)
    end

    test "concurrent deltas on existing item accumulate without silent lost updates" do
      suffix = System.unique_integer([:positive])

      {:ok, %{user: user, account: account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_conc_exist_#{suffix}",
          "account_id" => "acct_conc_exist_#{suffix}",
          "account_type" => "group",
          "subscription_tier" => "premium"
        })

      {:ok, %{user_id: user_id}} =
        Identity.ensure_persistent_identity(%{
          id: user.id,
          account_id: account.id,
          plan: :family_4
        })

      {:ok, ingredient} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Concurrent Existing Ingredient #{suffix}",
          category: :carnes,
          calories_per_100: 200,
          protein_g_per_100: Decimal.new("20.0"),
          carbs_g_per_100: Decimal.new("0.0"),
          fat_g_per_100: Decimal.new("10.0")
        })

      # Seed with initial 500g
      {:ok, seed} =
        PersistenceInventory.apply_delta_and_log(%{
          account_id: account.id,
          ingredient_id: ingredient.id,
          unit: :g,
          source_kind: :planned,
          delta: 500,
          source_user_id: user_id,
          trigger_type: :purchase,
          operation: :add
        })

      Sandbox.mode(Repo, {:shared, self()})

      deltas = [50, 100, 150, 200, 250, 50]
      expected_total = 500 + Enum.sum(deltas)

      tasks =
        Enum.map(deltas, fn delta ->
          Task.async(fn ->
            PersistenceInventory.apply_delta_and_log(%{
              account_id: account.id,
              ingredient_id: ingredient.id,
              unit: :g,
              source_kind: :planned,
              delta: delta,
              source_user_id: user_id,
              trigger_type: :purchase,
              operation: :add
            })
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      item = Repo.get!(InventoryItem, seed.item.id)
      assert item.quantity_milli == expected_total

      events =
        Repo.all(
          from(e in InventoryMutationEvent,
            where: e.inventory_item_id == ^item.id,
            order_by: [asc: e.inserted_at]
          )
        )

      assert length(events) == 1 + length(deltas)

      Enum.each(events, fn e ->
        assert e.quantity_before_milli + e.quantity_delta_milli == e.quantity_after_milli
      end)
    end

    test "concurrent deltas across different accounts remain strictly isolated" do
      suffix = System.unique_integer([:positive])

      {:ok, %{user: user_a, account: account_a}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_iso_a_#{suffix}",
          "account_id" => "acct_iso_a_#{suffix}",
          "account_type" => "group",
          "subscription_tier" => "premium"
        })

      {:ok, %{user_id: user_id_a}} =
        Identity.ensure_persistent_identity(%{
          id: user_a.id,
          account_id: account_a.id,
          plan: :family_4
        })

      {:ok, %{user: user_b, account: account_b}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_iso_b_#{suffix}",
          "account_id" => "acct_iso_b_#{suffix}",
          "account_type" => "group",
          "subscription_tier" => "premium"
        })

      {:ok, %{user_id: user_id_b}} =
        Identity.ensure_persistent_identity(%{
          id: user_b.id,
          account_id: account_b.id,
          plan: :family_4
        })

      {:ok, ingredient} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Concurrent Isolation Ingredient #{suffix}",
          category: :carnes,
          calories_per_100: 200,
          protein_g_per_100: Decimal.new("20.0"),
          carbs_g_per_100: Decimal.new("0.0"),
          fat_g_per_100: Decimal.new("10.0")
        })

      Sandbox.mode(Repo, {:shared, self()})

      deltas_a = [100, 200, 300]
      deltas_b = [50, 75, 125]

      tasks_a =
        Enum.map(deltas_a, fn delta ->
          Task.async(fn ->
            PersistenceInventory.apply_delta_and_log(%{
              account_id: account_a.id,
              ingredient_id: ingredient.id,
              unit: :g,
              source_kind: :planned,
              delta: delta,
              source_user_id: user_id_a,
              trigger_type: :purchase,
              operation: :add
            })
          end)
        end)

      tasks_b =
        Enum.map(deltas_b, fn delta ->
          Task.async(fn ->
            PersistenceInventory.apply_delta_and_log(%{
              account_id: account_b.id,
              ingredient_id: ingredient.id,
              unit: :g,
              source_kind: :planned,
              delta: delta,
              source_user_id: user_id_b,
              trigger_type: :purchase,
              operation: :add
            })
          end)
        end)

      Enum.each(tasks_a ++ tasks_b, &Task.await/1)

      items_a = PersistenceInventory.list_inventory(account_a.id)
      items_b = PersistenceInventory.list_inventory(account_b.id)

      assert length(items_a) == 1
      assert hd(items_a).quantity_milli == 600
      assert hd(items_a).account_id == account_a.id

      assert length(items_b) == 1
      assert hd(items_b).quantity_milli == 250
      assert hd(items_b).account_id == account_b.id
    end

    test "rollback boundary: invalid transaction rolls back both item state and mutation event" do
      suffix = System.unique_integer([:positive])

      {:ok, %{user: _user, account: account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_rb_#{suffix}",
          "account_id" => "acct_rb_#{suffix}",
          "account_type" => "group",
          "subscription_tier" => "premium"
        })

      {:ok, ingredient} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Rollback Ingredient #{suffix}",
          category: :carnes,
          calories_per_100: 200,
          protein_g_per_100: Decimal.new("20.0"),
          carbs_g_per_100: Decimal.new("0.0"),
          fat_g_per_100: Decimal.new("10.0")
        })

      # Pass non-existent foreign key source_user_id to trigger failure at mutation event step
      invalid_user_id = Ecto.UUID.generate()

      result =
        PersistenceInventory.apply_delta_and_log(%{
          account_id: account.id,
          ingredient_id: ingredient.id,
          unit: :g,
          source_kind: :planned,
          delta: 500,
          source_user_id: invalid_user_id,
          trigger_type: :purchase,
          operation: :add
        })

      assert {:error, _reason} = result

      # Verify that no inventory item was created
      items = PersistenceInventory.list_inventory(account.id)
      assert items == []

      # Verify that no mutation events exist
      events = Repo.all(from(e in InventoryMutationEvent, where: e.account_id == ^account.id))
      assert events == []
    end
  end

  defp noon_utc(date), do: DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

  defp lot_identity(label) do
    suffix = System.unique_integer([:positive])

    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "u_lot_#{label}_#{suffix}",
        "account_id" => "acct_lot_#{label}_#{suffix}",
        "account_type" => "group",
        "subscription_tier" => "premium"
      })

    {:ok, %{user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: user.id,
        account_id: account.id,
        plan: :family_4
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Lot ingredient #{label} #{suffix}",
        category: :otros
      })

    %{
      account: account,
      ingredient: ingredient,
      user: %{id: user.id, account_id: account.id},
      user_id: user_id
    }
  end
end
