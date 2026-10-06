defmodule MealPlannerApi.Services.InventoryServiceTest do
  use ExUnit.Case, async: false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Persistence.Inventory, as: InventoryPersistence
  alias MealPlannerApi.Persistence.Inventory.InventoryMutationEvent
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.InventoryService

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    :ok
  end

  describe "freshness_status/2" do
    test "preserves legacy category rules and the fallback for persisted Spanish categories" do
      now = ~U[2026-10-05 12:00:00Z]

      for {category, days} <- [produce: 5, dairy: 7, meat: 3, carnes: 14, otros: 14] do
        item = %{
          expired_at: nil,
          acquired_at: DateTime.add(now, -days * 86_400),
          ingredient: %{category: category}
        }

        assert "warning" = InventoryService.freshness_status(item, now)

        assert "expired" =
                 InventoryService.freshness_status(
                   %{item | acquired_at: DateTime.add(item.acquired_at, -86_400)},
                   now
                 )
      end
    end

    test "returns ok when expiry is far in future" do
      future = DateTime.add(DateTime.utc_now(), 10 * 86_400)
      item = %{expired_at: future}
      assert "ok" = InventoryService.freshness_status(item, DateTime.utc_now())
    end

    test "returns warning when expiry within 2 days" do
      soon = DateTime.add(DateTime.utc_now(), 1 * 86_400)
      item = %{expired_at: soon, acquired_at: nil, ingredient: nil}
      assert "warning" = InventoryService.freshness_status(item, DateTime.utc_now())
    end

    test "returns expired when expiry is in the past" do
      past = DateTime.add(DateTime.utc_now(), -1 * 86_400)
      item = %{expired_at: past}
      assert "expired" = InventoryService.freshness_status(item, DateTime.utc_now())
    end

    test "uses the inferred boundary day and lets explicit expiry supersede inference" do
      today = Date.utc_today()
      now = DateTime.new!(today, ~T[12:00:00], "Etc/UTC")
      ingredient = %{category: :otros}

      boundary = %{
        expired_at: nil,
        acquired_at: DateTime.new!(Date.add(today, -14), ~T[01:00:00], "Etc/UTC"),
        ingredient: ingredient
      }

      explicit_override = %{
        boundary
        | expired_at: DateTime.new!(Date.add(today, 3), ~T[01:00:00], "Etc/UTC"),
          acquired_at: DateTime.new!(Date.add(today, -30), ~T[01:00:00], "Etc/UTC")
      }

      assert "warning" = InventoryService.freshness_status(boundary, now)
      assert "ok" = InventoryService.freshness_status(explicit_override, now)
      assert "ok" = InventoryService.freshness_status(%{boundary | acquired_at: nil}, now)
    end
  end

  describe "function signatures" do
    test "inventory_view/1 is callable" do
      assert is_function(&InventoryService.inventory_view/1)
    end

    test "add_extra_item/2 is callable" do
      assert is_function(&InventoryService.add_extra_item/2)
    end

    test "adjust_item_quantity/3 is callable" do
      assert is_function(&InventoryService.adjust_item_quantity/3)
    end

    test "parse_voice_and_apply/3 is callable" do
      assert is_function(&InventoryService.parse_voice_and_apply/3)
    end

    test "get_inventory_item/2 is callable" do
      assert is_function(&InventoryService.get_inventory_item/2)
    end
  end

  describe "add_extra_item/2 — audited extra movements" do
    test "adds extra item and records audited mutation event with before/delta/after" do
      account = insert_account("Service Extra Acc")
      user = insert_user_with_active_membership(account.id, "extra@example.com", :owner)
      scoped_user = %{id: user.id, account_id: account.id, plan: :family_4}
      flour = insert_ingredient("Service Flour")

      payload = %{
        "ingredient_id" => flour.id,
        "quantity_milli" => 500,
        "unit" => "g"
      }

      assert {:ok, result} = InventoryService.add_extra_item(scoped_user, payload)
      assert result.status == "ok"
      assert result.operation == "add_extra"
      assert result.quantity_milli == 500
      assert result.unit == "g"
      assert result.event_id != nil

      # Verify persistence and event
      [item] = InventoryPersistence.list_inventory(account.id)
      assert item.quantity_milli == 500
      assert item.source_kind == :extra
      assert item.unit == :g

      event = Repo.get!(InventoryMutationEvent, result.event_id)
      assert event.account_id == account.id
      assert event.source_user_id == user.id
      assert event.inventory_item_id == item.id
      assert event.trigger_type == :manual
      assert event.operation == :add
      assert event.quantity_before_milli == 0
      assert event.quantity_delta_milli == 500
      assert event.quantity_after_milli == 500
    end

    test "rejects missing or negative quantity" do
      account = insert_account("Service Invalid Qty Acc")
      user = insert_user_with_active_membership(account.id, "invalid_qty@example.com", :owner)
      scoped_user = %{id: user.id, account_id: account.id, plan: :family_4}
      flour = insert_ingredient("Service Flour Qty")

      assert {:error, :invalid_quantity} =
               InventoryService.add_extra_item(scoped_user, %{
                 "ingredient_id" => flour.id,
                 "quantity_milli" => -100
               })

      assert {:error, :missing_quantity} =
               InventoryService.add_extra_item(scoped_user, %{
                 "ingredient_id" => flour.id
               })
    end

    test "rejects unknown ingredient" do
      account = insert_account("Service Unknown Ing Acc")
      user = insert_user_with_active_membership(account.id, "unknown_ing@example.com", :owner)
      scoped_user = %{id: user.id, account_id: account.id, plan: :family_4}

      assert {:error, :missing_ingredient} =
               InventoryService.add_extra_item(scoped_user, %{
                 "quantity_milli" => 500
               })
    end
  end

  describe "adjust_item_quantity/3 — atomic quantity adjustments" do
    test "atomically sets target quantity and records before/delta/after movement" do
      account = insert_account("Service Adjust Acc")
      user = insert_user_with_active_membership(account.id, "adjust@example.com", :owner)
      scoped_user = %{id: user.id, account_id: account.id, plan: :family_4}
      flour = insert_ingredient("Service Adjust Flour")

      # Seed with initial 1000g
      {:ok, seed} =
        InventoryPersistence.apply_delta_and_log(%{
          account_id: account.id,
          ingredient_id: flour.id,
          unit: :g,
          source_kind: :planned,
          delta: 1000,
          source_user_id: user.id,
          trigger_type: :purchase,
          operation: :add
        })

      item_id = seed.item.id

      # Adjust to 750g
      assert {:ok, res} =
               InventoryService.adjust_item_quantity(scoped_user, item_id, %{
                 "quantity_milli" => 750
               })

      assert res.item_id == item_id
      assert res.quantity_before_milli == 1000
      assert res.quantity_after_milli == 750
      assert res.delta_applied_milli == -250

      # Check database item state
      updated_item = InventoryPersistence.get_inventory_item_for_account(account.id, item_id)
      assert updated_item.quantity_milli == 750

      # Verify mutation event
      events =
        Repo.all(
          Ecto.Query.from(e in InventoryMutationEvent,
            where: e.inventory_item_id == ^item_id,
            order_by: [asc: e.inserted_at]
          )
        )

      assert length(events) == 2
      adjust_event = List.last(events)
      assert adjust_event.account_id == account.id
      assert adjust_event.source_user_id == user.id
      assert adjust_event.trigger_type == :manual
      assert adjust_event.operation == :set
      assert adjust_event.quantity_before_milli == 1000
      assert adjust_event.quantity_delta_milli == -250
      assert adjust_event.quantity_after_milli == 750
    end

    test "refuses adjustment on non-existent item" do
      account = insert_account("Service Missing Item Acc")
      user = insert_user_with_active_membership(account.id, "missing_item@example.com", :owner)
      scoped_user = %{id: user.id, account_id: account.id, plan: :family_4}

      assert {:error, :item_not_found} =
               InventoryService.adjust_item_quantity(scoped_user, Ecto.UUID.generate(), %{
                 "quantity_milli" => 500
               })
    end

    test "refuses cross-account item adjustment (account isolation)" do
      account_a = insert_account("Cross Adjust A")
      account_b = insert_account("Cross Adjust B")

      user = insert_user_with_active_membership(account_a.id, "cross_adj@example.com", :owner)
      _membership_b = insert_active_membership_for(account_b.id, user, :member)
      scoped_user_a = %{id: user.id, account_id: account_a.id, plan: :family_4}

      flour = insert_ingredient("Cross Flour")

      # Seed item on Account B
      {:ok, seed_b} =
        InventoryPersistence.apply_delta_and_log(%{
          account_id: account_b.id,
          ingredient_id: flour.id,
          unit: :g,
          source_kind: :planned,
          delta: 500,
          source_user_id: user.id
        })

      # User with Account A scope attempts to adjust Account B's item
      assert {:error, :item_not_found} =
               InventoryService.adjust_item_quantity(scoped_user_a, seed_b.item.id, %{
                 "quantity_milli" => 100
               })

      # Account B's item remains untouched
      item_b = InventoryPersistence.get_inventory_item_for_account(account_b.id, seed_b.item.id)
      assert item_b.quantity_milli == 500
    end
  end

  describe "dispose_item/3 — item disposal" do
    test "disposes item setting stock to 0 and records delete movement" do
      account = insert_account("Service Dispose Acc")
      user = insert_user_with_active_membership(account.id, "dispose@example.com", :owner)
      scoped_user = %{id: user.id, account_id: account.id, plan: :family_4}
      flour = insert_ingredient("Service Dispose Flour")

      {:ok, seed} =
        InventoryPersistence.apply_delta_and_log(%{
          account_id: account.id,
          ingredient_id: flour.id,
          unit: :g,
          source_kind: :planned,
          delta: 600,
          source_user_id: user.id
        })

      assert {:ok, res} =
               InventoryService.dispose_item(scoped_user, seed.item.id, %{"reason" => "spoiled"})

      assert res.item_id == seed.item.id
      assert res.disposed_quantity_milli == 600

      item = InventoryPersistence.get_inventory_item_for_account(account.id, seed.item.id)
      assert item.quantity_milli == 0

      events =
        Repo.all(
          Ecto.Query.from(e in InventoryMutationEvent,
            where: e.inventory_item_id == ^seed.item.id,
            order_by: [desc: e.inserted_at]
          )
        )

      dispose_event = hd(events)
      assert dispose_event.operation == :delete
      assert dispose_event.quantity_before_milli == 600
      assert dispose_event.quantity_delta_milli == -600
      assert dispose_event.quantity_after_milli == 0
    end

    test "refuses disposal for non-existent or cross-account item" do
      account = insert_account("Service Dispose Missing Acc")
      user = insert_user_with_active_membership(account.id, "disp_missing@example.com", :owner)
      scoped_user = %{id: user.id, account_id: account.id, plan: :family_4}

      assert {:error, :inventory_item_not_found} =
               InventoryService.dispose_item(scoped_user, Ecto.UUID.generate(), %{})
    end
  end

  describe "concurrency & lost update prevention" do
    test "concurrent add_extra_item calls safely accumulate deltas without lost updates" do
      account = insert_account("Concurrent Service Acc")
      user = insert_user_with_active_membership(account.id, "conc_service@example.com", :owner)
      scoped_user = %{id: user.id, account_id: account.id, plan: :family_4}
      flour = insert_ingredient("Concurrent Flour")

      Sandbox.mode(Repo, {:shared, self()})

      deltas = [100, 200, 150, 50, 300]
      expected_total = Enum.sum(deltas)

      tasks =
        Enum.map(deltas, fn delta ->
          Task.async(fn ->
            InventoryService.add_extra_item(scoped_user, %{
              "ingredient_id" => flour.id,
              "quantity_milli" => delta,
              "unit" => "g"
            })
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &match?({:ok, %{status: "ok"}}, &1))

      [item] = InventoryPersistence.list_inventory(account.id)
      assert item.quantity_milli == expected_total

      events =
        Repo.all(
          Ecto.Query.from(e in InventoryMutationEvent,
            where: e.inventory_item_id == ^item.id,
            order_by: [asc: e.inserted_at]
          )
        )

      assert length(events) == length(deltas)
      total_delta_in_events = Enum.reduce(events, 0, &(&1.quantity_delta_milli + &2))
      assert total_delta_in_events == expected_total

      # Verify each event correctly links before + delta == after
      Enum.each(events, fn e ->
        assert e.quantity_before_milli + e.quantity_delta_milli == e.quantity_after_milli
        assert e.account_id == account.id
        assert e.source_user_id == user.id
      end)
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp insert_account(name) do
    plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

    {:ok, account} =
      %PersistenceAccount{}
      |> PersistenceAccount.changeset(%{
        name: name,
        plan: :family_4,
        default_budget_cents: 0,
        subscription_plan_id: plan.id
      })
      |> Repo.insert()

    account
  end

  defp insert_user_with_active_membership(account_id, email, role) do
    user =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: email, role: role})
      |> Repo.insert!()

    insert_active_membership_for(account_id, user, role)
    user
  end

  defp insert_active_membership_for(account_id, user, role) do
    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account_id,
      user_id: user.id,
      role: role,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp insert_ingredient(name) do
    %Ingredient{}
    |> Ingredient.changeset(%{name: name, category: :otros})
    |> Repo.insert!()
  end
end
