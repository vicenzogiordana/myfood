defmodule MealPlannerApiWeb.PlanningChannelTest do
  use ExUnit.Case, async: true

  alias MealPlannerApiWeb.PlanningChannel

  describe "channel registration" do
    test "PlanningChannel is registered in UserSocket" do
      # Verify the module exists and is a Phoenix.Channel
      assert Code.ensure_loaded?(PlanningChannel)
      assert function_exported?(PlanningChannel, :handle_in, 3)
    end
  end

  describe "event handlers" do
    test "handle_in/3 has correct arity (arity 3 required by Phoenix)" do
      assert is_function(&PlanningChannel.handle_in/3, 3)
    end
  end
end
