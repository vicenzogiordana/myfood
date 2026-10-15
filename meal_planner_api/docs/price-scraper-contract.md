# Price scraper contract (external prerequisite of #101)

The planning agent's `lookup_prices` tool refreshes missing or stale prices
live from the `ratoneando-go` product scraper (spec #93, issue #101). Live
prices are only usable when the scraper says, for every price, **when it was
observed**, **whether it was served from cache** and **in which currency**.
Without these, a cached answer would look fresher than it is and freshness
could not be tracked per Product.

Status: **pending in `ratoneando-go`.** Until it ships, the HTTP adapter
(`MealPlannerApi.PlanningAgent.PriceScraper.Http`) drops every product that
lacks a required field. Stored prices are then kept with their real age and
a `refresh_failed` or `still_stale` warning, and missing prices stay missing.
Nothing is assumed.

## Request

```
GET <GO_SCRAPER_URL>/?q=<lowercased ingredient name>
```

In production `GO_SCRAPER_URL` must be set (read in `config/runtime.exs`);
without it the planning agent uses the `Unavailable` scraper and every
refresh fails as `scraper_unavailable`, instead of calling a localhost default.

## Response

```json
{
  "products": [
    {
      "source": "jumbo",
      "name": "Fideos spaghetti 500 g",
      "brand": "Luchetti",
      "price": 1250.0,
      "currency": "ARS",
      "packageQuantity": 500,
      "packageUnit": "g",
      "observedAt": "2026-10-15T09:00:00Z",
      "cached": true,
      "unavailable": false
    }
  ],
  "failedScrapers": ["carrefour"]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `source` | yes | Supermarket name; becomes the Product's supermarket |
| `name` | yes | Product name as sold |
| `brand` | no | Brand; empty or absent means unknown |
| `price` | yes | Regular price of one package, major currency units (no promotions) |
| `currency` | yes | ISO 4217 code, e.g. `ARS` |
| `packageQuantity` | yes | Package size, greater than zero |
| `packageUnit` | yes | `g`, `kg`, `ml`, `l` or `unit` |
| `observedAt` | yes | ISO 8601 time the scraper observed the price (not the request time) |
| `cached` | yes | `true` when served from the scraper's cache |
| `unavailable` | no | `true` drops the product |

## How the backend uses it

- Each product is stored as a Product of the queried Ingredient (keyed by
  supermarket, name and package) with a Price Observation at `observedAt`.
- A price is fresh when its latest observation is under 24 hours old. A
  cached observation keeps its own `observedAt`, so it can still be stale.
- A failed or unusable refresh records nothing: the previous price keeps its
  real age.
- Each live lookup is a read call (30 s, up to 2 retries on
  `scraper_unreachable` or timeout), clipped by the request's 5-minute
  deadline. It is not a model call and uses no iteration, spend or token
  allowance.
