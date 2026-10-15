defmodule MealPlannerApi.PlanningAgent.FakeScraper do
  @moduledoc """
  Hand-written price scraper fake for planning agent tests
  (`MealPlannerApi.PlanningAgent.PriceScraper`).

  Options:

    * `:responses` — map from a lowercased query to the answer of every call
      with that query: `{:ok, items}` or `{:error, reason}`; a query without
      an entry answers no items
    * `:notify` — receives `{:fake_scraper_fetch, query}` for every call
  """

  @behaviour MealPlannerApi.PlanningAgent.PriceScraper

  @impl true
  def fetch(query, opts) do
    if pid = Keyword.get(opts, :notify), do: send(pid, {:fake_scraper_fetch, query})

    opts
    |> Keyword.get(:responses, %{})
    |> Map.get(String.downcase(query), {:ok, []})
  end

  @doc "A scraped price item with fictitious defaults, overridden by `attrs`."
  def item(attrs) do
    Map.merge(
      %{
        supermarket: "Fictitious Live Market",
        product: "Fictitious live product",
        brand: nil,
        package_quantity_milli: 1_000_000,
        package_unit: :g,
        price_cents: 1_000,
        currency: "ARS",
        observed_at: ~U[2026-11-01 11:00:00.000000Z],
        cached?: false
      },
      Map.new(attrs)
    )
  end
end
