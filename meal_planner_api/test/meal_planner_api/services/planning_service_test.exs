defmodule MealPlannerApi.Services.PlanningServiceTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Services.PlanningService

  # The legacy weekly-plan generation and plan saving were switched off in
  # issue #110; plans come only from the culinary agent.
  test "no longer generates or saves plans" do
    refute function_exported?(PlanningService, :generate_weekly_plan, 3)
    refute function_exported?(PlanningService, :save_plan, 4)
  end

  describe "get_scheduled_meals/3" do
    test "accepts account_id with optional from_date and to_date" do
      assert is_function(&PlanningService.get_scheduled_meals/1)
      assert is_function(&PlanningService.get_scheduled_meals/2)
      assert is_function(&PlanningService.get_scheduled_meals/3)
    end
  end

  describe "mark_meal_cooked/1" do
    test "accepts meal_id" do
      assert is_function(&PlanningService.mark_meal_cooked/1)
    end
  end

  describe "delete_scheduled_meal/1" do
    test "accepts meal_id" do
      assert is_function(&PlanningService.delete_scheduled_meal/1)
    end
  end

  describe "start_cooking_session/3" do
    test "accepts account_id, user_id, scheduled_meal_id" do
      assert is_function(&PlanningService.start_cooking_session/3)
    end
  end

  describe "add_chat_message/2" do
    test "accepts session_id and content" do
      assert is_function(&PlanningService.add_chat_message/2)
    end
  end
end
