defmodule MealPlannerApi.PlanningAgent.PricesTest do
  @moduledoc """
  `MealPlannerApi.PlanningAgent.Prices` bounds (issue #101 review round):
  a Product search never refreshes more Ingredients than the lookup cap, and
  recording scraped data that the database rejects returns an error instead
  of raising inside the read tool.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Shopping.Product
  alias MealPlannerApi.PlanningAgent.{FakeScraper, Prices}
  alias MealPlannerApi.Repo

  @now ~U[2026-11-01 12:00:00.000000Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp hours_ago(hours), do: DateTime.add(@now, -hours * 3600, :second)

  describe "lookup/2 with a Product query" do
    test "refreshes at most the lookup cap of stale Ingredients" do
      search = "capped search #{System.unique_integer([:positive])}"

      for n <- 1..(Prices.max_ingredients() + 10) do
        ingredient = ingredient!("Fictitious capped #{n}")
        product!(ingredient, name: "#{search} #{n}", observed_at: hours_ago(30))
      end

      test_pid = self()

      refresh = fn name ->
        send(test_pid, {:refreshed, name})
        {:error, :scraper_unreachable}
      end

      result = Prices.lookup([], product: search, now: @now, refresh: refresh)

      {:messages, messages} = Process.info(self(), :messages)
      refreshed = Enum.count(messages, &match?({:refreshed, _}, &1))

      assert refreshed <= Prices.max_ingredients()
      assert length(result.prices) <= Prices.max_offers()
      assert length(result.warnings) <= Prices.max_ingredients()
    end
  end

  describe "record/2" do
    test "returns an error for a product name wider than its column, recording nothing" do
      ingredient = ingredient!("Fictitious record")
      item = FakeScraper.item(product: String.duplicate("x", 300))

      assert {:error, _reason} = Prices.record(ingredient.id, [item])
      assert Repo.aggregate(where(Product, ingredient_id: ^ingredient.id), :count) == 0
    end

    test "returns an error for an item the Product rejects, recording nothing" do
      ingredient = ingredient!("Fictitious record")
      good = FakeScraper.item(product: "Fictitious good product")
      bad = FakeScraper.item(product: "Fictitious bad product", package_quantity_milli: 0)

      assert {:error, _reason} = Prices.record(ingredient.id, [good, bad])
      assert Repo.aggregate(where(Product, ingredient_id: ^ingredient.id), :count) == 0
    end

    test "reuses an existing Product instead of conflicting with it" do
      ingredient = ingredient!("Fictitious record")
      item = FakeScraper.item(product: "Fictitious shared product")

      assert :ok = Prices.record(ingredient.id, [item])

      assert :ok =
               Prices.record(ingredient.id, [Map.put(item, :observed_at, hours_ago(1))])

      assert Repo.aggregate(where(Product, ingredient_id: ^ingredient.id), :count) == 1
    end
  end
end
