defmodule MealPlannerApi.Data.InventoryRepoTest do
  @moduledoc """
  Tests for `MealPlannerApi.Data.InventoryRepo` — Phase A — Tenancy
  Refactor, PR 2b task 2.14.

  Coverage:

    * `list_inventory/1`, `list_inventory_with_ingredient/1` — filter
      by `account_id` so a multi-familia User with inventory in
      Account A and Account B never sees the other account's items
      through either lookup.
    * `get_inventory_item_for_account/2` — refuses an `item_id` that
      belongs to a different account.
    * `find_inventory_item_by_ingredient/4` — same scope.
    * `list_mutations/3` — same scope, by date range.
    * `apply_delta/1` — operates atomically against the requested
      account_id; a delta applied to Account A never mutates
      Account B's inventory even if a User is a member of both.

  Pre-PR-2b the existing test only asserted function arity (smoke
  tests). This PR replaces them with real behavioral assertions.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Data.InventoryRepo
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "list_inventory/1 — account_id scoping" do
    test "returns only the inventory items for the requested account" do
      account_a = insert_account("Inv A")
      account_b = insert_account("Inv B")

      user = insert_user_with_active_membership(account_a.id, "inv-multi@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      flour = insert_ingredient("Flour")
      sugar = insert_ingredient("Sugar")
      salt = insert_ingredient("Salt")

      {:ok, item_a1} =
        InventoryRepo.upsert_inventory_item(%{
          account_id: account_a.id,
          ingredient_id: flour.id,
          quantity_milli: 1_000_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      {:ok, item_a2} =
        InventoryRepo.upsert_inventory_item(%{
          account_id: account_a.id,
          ingredient_id: sugar.id,
          quantity_milli: 500_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      {:ok, _item_b1} =
        InventoryRepo.upsert_inventory_item(%{
          account_id: account_b.id,
          ingredient_id: salt.id,
          quantity_milli: 100_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      list_a = InventoryRepo.list_inventory(account_a.id)
      list_b = InventoryRepo.list_inventory(account_b.id)

      assert length(list_a) == 2
      assert Enum.all?(list_a, &(&1.account_id == account_a.id))
      assert Enum.map(list_a, & &1.id) |> Enum.sort() ==
               Enum.sort([item_a1.id, item_a2.id])

      assert length(list_b) == 1
      assert hd(list_b).account_id == account_b.id
    end
  end

  describe "get_inventory_item_for_account/2 — rejects cross-account item_ids" do
    test "returns the item when it belongs to the requested account" do
      account = insert_account("Self Inv")
      _user = insert_user_with_active_membership(account.id, "self-inv@example.com", :owner)
      flour = insert_ingredient("Self Flour")

      {:ok, item} =
        InventoryRepo.create_inventory_item(%{
          account_id: account.id,
          ingredient_id: flour.id,
          quantity_milli: 500_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      fetched = InventoryRepo.get_inventory_item_for_account(account.id, item.id)
      assert fetched.id == item.id
    end

    test "returns nil when the item belongs to a different account" do
      account_a = insert_account("Cross Inv A")
      account_b = insert_account("Cross Inv B")

      user = insert_user_with_active_membership(account_a.id, "cross-inv@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      flour = insert_ingredient("Cross Flour")

      {:ok, _item_a} =
        InventoryRepo.create_inventory_item(%{
          account_id: account_a.id,
          ingredient_id: flour.id,
          quantity_milli: 500_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      {:ok, item_b} =
        InventoryRepo.create_inventory_item(%{
          account_id: account_b.id,
          ingredient_id: flour.id,
          quantity_milli: 500_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      # Caller has Account_A scope — item_b's id should NOT resolve.
      assert InventoryRepo.get_inventory_item_for_account(account_a.id, item_b.id) == nil
    end
  end

  describe "find_inventory_item_by_ingredient/4 — scoped to account_id" do
    test "finds the item by (account_id, ingredient_id, unit, source_kind) without crossing accounts" do
      account_a = insert_account("Find A")
      account_b = insert_account("Find B")

      _user = insert_user_with_active_membership(account_a.id, "find-inv@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, _user, :member)

      flour = insert_ingredient("Find Flour")

      {:ok, item_a} =
        InventoryRepo.create_inventory_item(%{
          account_id: account_a.id,
          ingredient_id: flour.id,
          quantity_milli: 100_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      {:ok, _item_b} =
        InventoryRepo.create_inventory_item(%{
          account_id: account_b.id,
          ingredient_id: flour.id,
          quantity_milli: 200_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      found_a = InventoryRepo.find_inventory_item_by_ingredient(account_a.id, flour.id, :g, :planned)
      found_b = InventoryRepo.find_inventory_item_by_ingredient(account_b.id, flour.id, :g, :planned)

      assert found_a.id == item_a.id
      assert found_a.account_id == account_a.id
      refute found_a.id == _item_b.id

      assert found_b.account_id == account_b.id
      assert found_b.id == _item_b.id
    end
  end

  describe "list_mutations/3 — scoped to account_id" do
    test "returns only mutations for the requested account" do
      account_a = insert_account("Mut A")
      account_b = insert_account("Mut B")

      user = insert_user_with_active_membership(account_a.id, "mut-multi@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      flour = insert_ingredient("Mut Flour")
      sugar = insert_ingredient("Mut Sugar")

      {:ok, item_a} =
        InventoryRepo.create_inventory_item(%{
          account_id: account_a.id,
          ingredient_id: flour.id,
          quantity_milli: 1_000_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      {:ok, item_b} =
        InventoryRepo.create_inventory_item(%{
          account_id: account_b.id,
          ingredient_id: sugar.id,
          quantity_milli: 1_000_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      {:ok, _mutation_a} =
        InventoryRepo.append_mutation(%{
          account_id: account_a.id,
          inventory_item_id: item_a.id,
          trigger_type: :manual,
          operation: :add,
          quantity_before_milli: 0,
          quantity_delta_milli: 1_000_000,
          quantity_after_milli: 1_000_000,
          source_user_id: user.id
        })

      {:ok, _mutation_b} =
        InventoryRepo.append_mutation(%{
          account_id: account_b.id,
          inventory_item_id: item_b.id,
          trigger_type: :manual,
          operation: :add,
          quantity_before_milli: 0,
          quantity_delta_milli: 1_000_000,
          quantity_after_milli: 1_000_000,
          source_user_id: user.id
        })

      today = Date.utc_today()
      now = DateTime.utc_now()

      from_dt = DateTime.new!(Date.add(today, -1), ~T[00:00:00.000])
      to_dt = DateTime.new!(Date.add(today, 1), ~T[23:59:59.999])

      list_a = InventoryRepo.list_mutations(account_a.id, from_dt, to_dt)
      list_b = InventoryRepo.list_mutations(account_b.id, from_dt, to_dt)

      assert length(list_a) == 1
      assert hd(list_a).account_id == account_a.id

      assert length(list_b) == 1
      assert hd(list_b).account_id == account_b.id
    end
  end

  describe "apply_delta/1 — atomic per-account mutation" do
    test "a positive delta on Account A leaves Account B untouched" do
      account_a = insert_account("Delta A")
      account_b = insert_account("Delta B")

      user = insert_user_with_active_membership(account_a.id, "delta@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      flour = insert_ingredient("Delta Flour")

      {:ok, item_b_initial} =
        InventoryRepo.create_inventory_item(%{
          account_id: account_b.id,
          ingredient_id: flour.id,
          quantity_milli: 100_000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now()
        })

      # Apply delta to Account A — this should create a NEW item on A
      # and not touch B's existing item.
      assert {:ok, %{item_state: %{item: item_a, before_qty: 0, after_qty: 500_000}}} =
               InventoryRepo.apply_delta(%{
                 account_id: account_a.id,
                 ingredient_id: flour.id,
                 unit: :g,
                 source_kind: :planned,
                 delta: 500_000,
                 source_user_id: user.id
               })

      assert item_a.account_id == account_a.id
      assert item_a.quantity_milli == 500_000

      # Account B's item is unchanged.
      item_b_after =
        InventoryRepo.get_inventory_item_for_account(account_b.id, item_b_initial.id)

      assert item_b_after.quantity_milli == 100_000
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
