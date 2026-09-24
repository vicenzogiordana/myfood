defmodule MealPlannerApi.Services.ShoppingRebuilderTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Services.ShoppingRebuilder

  # Helpers ----------------------------------------------------------------

  defp meal(id, date, recipe_ingredients) do
    %{
      id: id,
      recipe_id: "recipe-#{id}",
      date: date,
      recipe: %{recipe_ingredients: recipe_ingredients}
    }
  end

  defp ri(ingredient_id, unit, quantity_milli) do
    %{ingredient_id: ingredient_id, unit: unit, quantity_milli: quantity_milli}
  end

  # -------------------------------------------------------------------------
  # Scenario: Partial inventory yields the exact shortage
  # Spec: AC #3 / story 16 — 200_000 needed, 100_000 available → 100_000
  # -------------------------------------------------------------------------

  describe "compute_net_shortages/2 — partial inventory" do
    test "returns exact shortage when inventory covers part of the need" do
      meals = [meal("m1", ~D[2026-09-25], [ri("flour", :g, 200_000)])]
      pool = %{{"flour", :g} => 100_000}

      result = ShoppingRebuilder.compute_net_shortages(meals, pool)

      assert [%{quantity_milli: 100_000, ingredient_id: "flour", unit: :g}] = result
    end
  end

  # -------------------------------------------------------------------------
  # Scenario: Surplus inventory floors shortage at zero
  # Spec: AC #3 / story 16 — 200_000 needed, 300_000 available → no row
  # -------------------------------------------------------------------------

  describe "compute_net_shortages/2 — surplus inventory" do
    test "returns no row when inventory fully covers the need" do
      meals = [meal("m1", ~D[2026-09-25], [ri("flour", :g, 200_000)])]
      pool = %{{"flour", :g} => 300_000}

      result = ShoppingRebuilder.compute_net_shortages(meals, pool)

      assert result == []
    end
  end

  # -------------------------------------------------------------------------
  # Scenario: Mixed recipe units remain separate
  # Spec: AC #3 / story 16 — milk as :ml and milk as :g → two rows
  # -------------------------------------------------------------------------

  describe "compute_net_shortages/2 — mixed units" do
    test "same ingredient with different units produces separate rows" do
      meals = [
        meal("m1", ~D[2026-09-25], [
          ri("milk", :ml, 500_000),
          ri("milk", :g, 100_000)
        ])
      ]

      pool = %{}

      result = ShoppingRebuilder.compute_net_shortages(meals, pool)

      assert length(result) == 2
      assert Enum.any?(result, &(&1.unit == :ml and &1.quantity_milli == 500_000))
      assert Enum.any?(result, &(&1.unit == :g and &1.quantity_milli == 100_000))
    end
  end

  # -------------------------------------------------------------------------
  # Scenario: Exact differences are not rounded
  # Spec: AC #3 / story 16 — flour 33_000 needed, 10_000 available → 23_000
  # -------------------------------------------------------------------------

  describe "compute_net_shortages/2 — no rounding" do
    test "returns exact integer difference without any rounding" do
      meals = [meal("m1", ~D[2026-09-25], [ri("flour", :g, 33_000)])]
      pool = %{{"flour", :g} => 10_000}

      result = ShoppingRebuilder.compute_net_shortages(meals, pool)

      assert [%{quantity_milli: 23_000}] = result
    end
  end

  # -------------------------------------------------------------------------
  # Scenario: Multi-meal greedy pool depletion
  # Pool 150_000 flour; meal1 needs 100_000, meal2 needs 100_000
  # → meal1 gets 0 shortage (fully covered), meal2 gets 50_000 shortage
  # -------------------------------------------------------------------------

  describe "compute_net_shortages/2 — greedy pool across meals" do
    test "depletes pool greedily across multiple meals" do
      meals = [
        meal("m1", ~D[2026-09-25], [ri("flour", :g, 100_000)]),
        meal("m2", ~D[2026-09-26], [ri("flour", :g, 100_000)])
      ]

      pool = %{{"flour", :g} => 150_000}

      result = ShoppingRebuilder.compute_net_shortages(meals, pool)

      # meal1 is fully covered (0 shortage → no row), meal2 has 50_000 shortage
      assert [%{scheduled_meal_id: "m2", quantity_milli: 50_000}] = result
    end
  end

  # -------------------------------------------------------------------------
  # Scenario: Empty meals returns empty list
  # -------------------------------------------------------------------------

  describe "compute_net_shortages/2 — empty meals" do
    test "returns empty list when no meals provided" do
      assert ShoppingRebuilder.compute_net_shortages([], %{}) == []
    end
  end

  # -------------------------------------------------------------------------
  # Scenario: Nil recipe_id meals are skipped
  # -------------------------------------------------------------------------

  describe "compute_net_shortages/2 — nil recipe" do
    test "skips meals with nil recipe_id" do
      meals = [%{id: "m1", recipe_id: nil, date: ~D[2026-09-25], recipe: nil}]

      result = ShoppingRebuilder.compute_net_shortages(meals, %{})

      assert result == []
    end
  end

  # -------------------------------------------------------------------------
  # Scenario: Per-meal grain preserves scheduled_meal_id and planned_date
  # -------------------------------------------------------------------------

  describe "compute_net_shortages/2 — output shape" do
    test "each row carries scheduled_meal_id and planned_date" do
      meals = [meal("m1", ~D[2026-09-25], [ri("salt", :g, 5_000)])]
      pool = %{}

      [row] = ShoppingRebuilder.compute_net_shortages(meals, pool)

      assert row.scheduled_meal_id == "m1"
      assert row.planned_date == ~D[2026-09-25]
      assert row.ingredient_id == "salt"
      assert row.unit == :g
      assert row.quantity_milli == 5_000
    end
  end
end
