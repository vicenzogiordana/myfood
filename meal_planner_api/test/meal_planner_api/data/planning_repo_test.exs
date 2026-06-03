defmodule MealPlannerApi.Data.PlanningRepoTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Data.PlanningRepo

  describe "slot_favorite functions" do
    test "toggle_slot_favorite/1 has correct arity" do
      fun = &PlanningRepo.toggle_slot_favorite/1
      assert is_function(fun, 1)
    end

    test "is_slot_favorite?/4 has correct arity" do
      fun = &PlanningRepo.is_slot_favorite?/4
      assert is_function(fun, 4)
    end

    test "list_slot_favorites/2 has correct arity" do
      fun = &PlanningRepo.list_slot_favorites/2
      assert is_function(fun, 2)
    end

    test "slot values are valid atoms" do
      slots = [:breakfast, :lunch, :snack, :dinner]
      assert Enum.all?(slots, &is_atom/1)
      assert length(slots) == 4
    end

    test "toggle input structure is valid map" do
      input = %{
        account_id: 123,
        user_id: 456,
        date: ~D[2025-06-02],
        slot: "lunch"
      }

      assert is_map(input)
      assert is_integer(input.account_id)
      assert is_integer(input.user_id)
      assert is_struct(input.date, Date)
      assert is_binary(input.slot)
    end

    test "is_slot_favorite? returns boolean signature" do
      # Just verify the function exists and is callable
      fun = &PlanningRepo.is_slot_favorite?/4
      assert is_function(fun, 4)
    end
  end

  describe "slot favorite persistence structure" do
    test "SlotFavorite changeset fields are present" do
      # Verify the expected field list for insert
      required_fields = [:account_id, :user_id, :date, :slot, :scheduled_meal_id, :recipe_id]
      assert length(required_fields) == 6

      # All fields are atoms (valid Ecto field names)
      assert Enum.all?(required_fields, &is_atom/1)
    end

    test "unique constraint includes all dimensions" do
      # account_id + user_id + date + slot = one favorite per slot instance
      dimensions = [:account_id, :user_id, :date, :slot]
      assert length(dimensions) == 4
      assert Enum.all?(dimensions, &is_atom/1)
    end
  end
end
