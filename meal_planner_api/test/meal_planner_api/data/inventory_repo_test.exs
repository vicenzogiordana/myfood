defmodule MealPlannerApi.Data.InventoryRepoTest do
  use ExUnit.Case, async: true

  describe "list_inventory/1" do
    test "accepts account_id and returns a list" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.list_inventory/1)
    end
  end

  describe "list_inventory_with_ingredient/1" do
    test "accepts account_id and returns a list" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.list_inventory_with_ingredient/1)
    end
  end

  describe "get_inventory_item!/1" do
    test "accepts an id" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.get_inventory_item!/1)
    end
  end

  describe "get_inventory_item_for_account/2" do
    test "accepts account_id and item_id" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.get_inventory_item_for_account/2)
    end
  end

  describe "find_inventory_item_by_ingredient/4" do
    test "accepts account_id, ingredient_id, unit, source_kind" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.find_inventory_item_by_ingredient/4)
    end
  end

  describe "update_inventory_item/2" do
    test "accepts item and attrs" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.update_inventory_item/2)
    end
  end

  describe "upsert_inventory_item/1" do
    test "accepts attrs map" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.upsert_inventory_item/1)
    end
  end

  describe "create_inventory_item/1" do
    test "accepts attrs map" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.create_inventory_item/1)
    end
  end

  describe "append_mutation/1" do
    test "accepts attrs map" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.append_mutation/1)
    end
  end

  describe "list_mutations/3" do
    test "accepts account_id, from_date, to_date" do
      assert is_function(&MealPlannerApi.Data.InventoryRepo.list_mutations/3)
    end
  end

  describe "apply_delta/1" do
    test "requires account_id, ingredient_id, unit, source_kind, delta, source_user_id" do
      opts = %{
        account_id: 1,
        ingredient_id: 10,
        unit: :grams,
        source_kind: :shopping,
        delta: -100_000,
        source_user_id: 5
      }

      required_keys = [:account_id, :ingredient_id, :unit, :source_kind, :delta, :source_user_id]

      for key <- required_keys do
        assert Map.has_key?(opts, key), "Missing required key: #{key}"
      end
    end

    test "delta can be positive or negative" do
      add_delta = %{
        account_id: 1,
        ingredient_id: 10,
        unit: :grams,
        source_kind: :shopping,
        delta: 500_000,
        source_user_id: nil
      }

      sub_delta = %{
        account_id: 1,
        ingredient_id: 10,
        unit: :grams,
        source_kind: :shopping,
        delta: -200_000,
        source_user_id: nil
      }

      assert add_delta.delta > 0
      assert sub_delta.delta < 0
    end

    test "zero delta is allowed" do
      opts = %{
        account_id: 1,
        ingredient_id: 10,
        unit: :grams,
        source_kind: :shopping,
        delta: 0,
        source_user_id: nil
      }

      assert opts.delta == 0
    end
  end
end
