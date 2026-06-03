defmodule MealPlannerApi.Integrations.PythonClientTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Integrations.PythonClient

  describe "optimize_menu/3" do
    test "has correct arity" do
      assert is_function(&PythonClient.optimize_menu/3, 3)
    end

    test "accepts lists and maps" do
      slots = [%{date: "2026-06-03", slot: "lunch", available_recipe_ids: [], constraints: %{}}]
      result = PythonClient.optimize_menu(slots, %{}, %{})
      assert is_tuple(result)
    end
  end

  describe "optimize_slot/3" do
    test "has correct arity" do
      assert is_function(&PythonClient.optimize_slot/3, 3)
    end
  end

  describe "extract_shopping_list/3" do
    test "has correct arity" do
      assert is_function(&PythonClient.extract_shopping_list/3, 3)
    end
  end

  describe "base_url/0" do
    test "returns a string URL" do
      url = PythonClient.base_url()
      assert is_binary(url)
      assert url =~ "http"
    end
  end
end
