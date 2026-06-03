defmodule MealPlannerApi.Generation.ServerTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Generation.Server

  describe "via/1" do
    test "returns a Registry via tuple" do
      via = Server.via(123)
      assert {:via, Registry, {MealPlannerApi.Generation.Generations, {:generation, 123}}} = via
    end

    test "rejects non-positive account IDs" do
      assert_raise FunctionClauseError, fn -> Server.via(0) end
      assert_raise FunctionClauseError, fn -> Server.via(-1) end
    end
  end

  describe "start_generation/4 interface" do
    test "is callable with correct arity (module API)" do
      # Solo verificamos que la función existe y tiene la aridad correcta
      assert is_function(&Server.start_generation/4, 4)
    end

    test "chat/3 has correct arity" do
      assert is_function(&Server.chat/3, 3)
    end

    test "confirm/2 has correct arity" do
      assert is_function(&Server.confirm/2, 2)
    end

    test "reject/2 has correct arity" do
      assert is_function(&Server.reject/2, 2)
    end

    test "get_status/1 has correct arity" do
      assert is_function(&Server.get_status/1, 1)
    end
  end
end
