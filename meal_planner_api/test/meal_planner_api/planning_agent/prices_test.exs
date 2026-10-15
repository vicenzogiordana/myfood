defmodule MealPlannerApi.PlanningAgent.PricesTest do
  @moduledoc """
  `MealPlannerApi.PlanningAgent.Prices` bounds (issue #101 review round):
  a lookup or a Product search never refreshes more Ingredients than the
  lookup cap, and recording scraped data that the database rejects returns
  an error instead of raising inside the read tool.
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

  describe "lookup/2 with more Ingredients than the cap" do
    test "refreshes at most the lookup cap of stale Ingredients" do
      prefix = "Fictitious capped #{System.unique_integer([:positive])}"

      names =
        for n <- 1..(Prices.max_ingredients() + 10) do
          ingredient = ingredient!("#{prefix} #{n}")
          product!(ingredient, observed_at: hours_ago(30))
          ingredient.name
        end

      test_pid = self()

      refresh = fn name ->
        send(test_pid, {:refreshed, name})
        {:error, :scraper_unavailable}
      end

      result = Prices.lookup(names, now: @now, refresh: refresh)

      {:messages, messages} = Process.info(self(), :messages)
      refreshed = Enum.count(messages, &match?({:refreshed, _}, &1))

      assert refreshed == Prices.max_ingredients()
      assert length(result.prices) <= Prices.max_offers()
      assert length(result.warnings) == Prices.max_ingredients()
    end
  end

  describe "lookup/2 with a Product query" do
    test "refreshes at most the lookup cap of stale matching Ingredients" do
      search = "capped search #{System.unique_integer([:positive])}"

      for n <- 1..(Prices.max_ingredients() + 10) do
        ingredient = ingredient!("Fictitious searched #{n}")
        product!(ingredient, name: "#{search} #{n}", observed_at: hours_ago(30))
      end

      test_pid = self()

      refresh = fn name ->
        send(test_pid, {:refreshed, name})
        {:error, :scraper_unavailable}
      end

      result = Prices.lookup([], product: search, now: @now, refresh: refresh)

      {:messages, messages} = Process.info(self(), :messages)
      refreshed = Enum.count(messages, &match?({:refreshed, _}, &1))

      assert refreshed == Prices.max_ingredients()
      assert length(result.prices) <= Prices.max_offers()
      assert length(result.warnings) == Prices.max_ingredients()
    end
  end

  describe "lookup/2 when the scraper is down" do
    # Reason => Ingredients memoized: only the attempted one, never a deadline.
    for {reason, memoized} <- [scraper_timeout: 1, scraper_unreachable: 1, deadline_exceeded: 0] do
      test "stops calling the scraper after the first #{reason}" do
        reason = unquote(reason)
        ingredients = for n <- 1..5, do: ingredient!("Fictitious breaker #{n}")
        names = Enum.map(ingredients, & &1.name)
        ids = Enum.map(ingredients, & &1.id)
        test_pid = self()

        refresh = fn name ->
          send(test_pid, {:refreshed, name})
          {:error, reason}
        end

        result = Prices.lookup(names, now: @now, refresh: refresh)

        {:messages, messages} = Process.info(self(), :messages)
        assert Enum.count(messages, &match?({:refreshed, _}, &1)) == 1

        assert Enum.sort(Enum.map(result.warnings, & &1.ingredient)) == Enum.sort(names)

        assert Enum.all?(
                 result.warnings,
                 &(&1.reason == :refresh_failed and &1.detail == reason)
               )

        # The next lookup retries every Ingredient left out of the memo.
        assert map_size(result.refresh_memo) == unquote(memoized)
        assert Enum.all?(Map.keys(result.refresh_memo), &(&1 in ids))
      end
    end

    test "the next lookup retries the Ingredients that were skipped" do
      names = for n <- 1..3, do: ingredient!("Fictitious retry #{n}").name

      first =
        Prices.lookup(names, now: @now, refresh: fn _name -> {:error, :scraper_timeout} end)

      test_pid = self()

      refresh = fn name ->
        send(test_pid, {:refreshed, name})
        {:ok, []}
      end

      Prices.lookup(names, now: @now, refresh: refresh, refresh_memo: first.refresh_memo)

      {:messages, messages} = Process.info(self(), :messages)
      assert Enum.count(messages, &match?({:refreshed, _}, &1)) == 2
    end
  end

  describe "lookup/2 with more offers than the cap" do
    test "keeps the cheapest offers of every requested Ingredient and flags the cut" do
      # A plain global take would drop the alphabetically last Ingredients.
      ingredients = for n <- 1..5, do: ingredient!("Fictitious many #{n}")
      names = Enum.map(ingredients, & &1.name)

      for ingredient <- ingredients do
        for p <- 1..div(Prices.max_offers(), 2) do
          product!(ingredient,
            name: "#{ingredient.name} product #{p}",
            price_cents: 100 + p,
            observed_at: @now
          )
        end
      end

      result = Prices.lookup(names, now: @now)

      assert length(result.prices) == Prices.max_offers()
      assert result.missing == []

      for name <- names do
        kept =
          result.prices
          |> Enum.filter(&(&1.ingredient == name))
          |> Enum.map(& &1.price_cents)

        assert kept != []
        assert kept == Enum.to_list(101..(100 + length(kept)))

        assert %{reason: :offers_truncated} =
                 Enum.find(result.warnings, &(&1.ingredient == name))
      end
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

      assert :ok = Prices.record(ingredient.id, [item], @now)

      assert :ok =
               Prices.record(ingredient.id, [Map.put(item, :observed_at, hours_ago(1))], @now)

      assert Repo.aggregate(where(Product, ingredient_id: ^ingredient.id), :count) == 1
    end

    test "keeps the stored brand when a later scrape omits it, and updates a new one" do
      ingredient = ingredient!("Fictitious brand record")
      item = FakeScraper.item(product: "Fictitious branded product", brand: "Acme")
      brand = fn -> Repo.get_by!(Product, ingredient_id: ingredient.id).brand end

      assert :ok = Prices.record(ingredient.id, [item], @now)
      assert brand.() == "Acme"

      assert :ok = Prices.record(ingredient.id, [%{item | brand: nil}], @now)
      assert brand.() == "Acme"

      assert :ok = Prices.record(ingredient.id, [%{item | brand: "Globex"}], @now)
      assert brand.() == "Globex"
    end

    test "rejects an observation dated after now, recording nothing" do
      ingredient = ingredient!("Fictitious future record")
      good = FakeScraper.item(product: "Fictitious present product", observed_at: @now)

      future =
        FakeScraper.item(
          product: "Fictitious future product",
          observed_at: DateTime.add(@now, 3, :day)
        )

      assert {:error, :record_failed} = Prices.record(ingredient.id, [good, future], @now)
      assert Repo.aggregate(where(Product, ingredient_id: ^ingredient.id), :count) == 0
    end

    test "accepts an observation within the clock skew tolerance" do
      ingredient = ingredient!("Fictitious skewed record")

      item =
        FakeScraper.item(
          product: "Fictitious skewed product",
          observed_at: DateTime.add(@now, 60, :second)
        )

      assert :ok = Prices.record(ingredient.id, [item], @now)
    end
  end

  describe "lookup/2 with a future-dated scrape" do
    test "fails the refresh and keeps later real observations winning" do
      ingredient = ingredient!("Fictitious future lookup")

      product!(ingredient,
        supermarket: "Fictitious Live Market",
        name: "Fictitious future lookup product",
        observed_at: hours_ago(30)
      )

      future =
        FakeScraper.item(
          product: "Fictitious future lookup product",
          observed_at: DateTime.add(@now, 3, :day)
        )

      first = Prices.lookup([ingredient.name], now: @now, refresh: fn _ -> {:ok, [future]} end)

      assert [%{reason: :refresh_failed, detail: :record_failed}] = first.warnings
      assert [%{fresh?: false}] = first.prices

      # A real observation scraped later is the one the lookup returns.
      real =
        FakeScraper.item(product: "Fictitious future lookup product", observed_at: hours_ago(1))

      test_pid = self()

      refresh = fn name ->
        send(test_pid, {:refreshed, name})
        {:ok, [real]}
      end

      second =
        Prices.lookup([ingredient.name], now: DateTime.add(@now, 3600, :second), refresh: refresh)

      assert_received {:refreshed, _name}
      assert [%{fresh?: true, observed_at: observed_at}] = second.prices
      assert DateTime.compare(observed_at, hours_ago(1)) == :eq
    end
  end
end
