defmodule MealPlannerApi.PlanningAgent.PriceScraper do
  @moduledoc """
  Port to the live product scraper used by `lookup_prices` (spec #93, user
  stories 44-47).

  A fetch answers the scraped prices for one query (an Ingredient name).
  Every item carries its own observation time, cache flag and currency: the
  observation time is when the scraper saw the price, not when it was asked,
  so a cached answer never looks fresher than it is. Items lacking any of
  these are dropped by the adapter, never completed with assumed values.

  The scraper prerequisite (`ratoneando-go` exposing observation time, cache
  flag and currency per price) is tracked in `docs/price-scraper-contract.md`.

  Errors: `:scraper_unreachable` and `:timeout` are transient and retried
  within the read-call budget; `:scraper_unavailable` (not configured) and
  `:invalid_scraper_response` are not.
  """

  @type item :: %{
          supermarket: String.t(),
          product: String.t(),
          brand: String.t() | nil,
          package_quantity_milli: pos_integer(),
          package_unit: :g | :ml | :unit,
          price_cents: non_neg_integer(),
          currency: String.t(),
          observed_at: DateTime.t(),
          cached?: boolean()
        }

  @callback fetch(query :: String.t(), opts :: keyword()) ::
              {:ok, [item()]} | {:error, atom()}
end
