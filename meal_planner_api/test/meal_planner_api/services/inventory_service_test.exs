defmodule MealPlannerApi.Services.InventoryServiceTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Services.InventoryService

  describe "freshness_status/2" do
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
end
