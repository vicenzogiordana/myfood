# Live prices, freshness and brands (#101, part of #93)

## Objective

Keep prices current and honest, and let brands steer Product choice softly:
`lookup_prices` reads the database first and calls the product scraper live
when a price is missing or older than 24 hours; Household Brand Preferences
and Session Brands steer the Purchase without ever swapping a chosen brand
silently.

## Problem and why

After #100 the agent reads stored Price Observations only. Nothing refreshes
them, nothing says how old they are, and brands have no influence on which
Product the Purchase buys. Spec #93 (user stories 44-54) requires fresh
prices, honest staleness, brand and Product queries, and brand choices that
are never swapped without telling the Member.

## Product decisions applied

- Spend, token and iteration caps are per Planning Session and count model
  (OpenAI) calls only (user decision 2026-10-15, "tope por sesion"). Live
  scraper calls are not model calls: they do not consume iterations or the
  paid-service spend cap; each one is a read call bounded by `CallBounds`
  (30 s, 2 retries) and clipped by the request's global deadline.
- A price is fresh when its latest Price Observation is under 24 hours old.
- A live lookup records the scraper's own observation time, never the time
  of the request, so a cached or failed refresh never renews a price's age.
- Session Brands are set through a dedicated `set_session_brand` tool
  because `edit_workspace` lands separately in #99; the edit is visible to
  the Member as a `session_brand_changed` event.

## Scope

- Price scraper port (`PriceScraper` behaviour), HTTP adapter for the
  prerequisite contract, `Unavailable` default for tests, fake scraper in
  test support.
- Freshness and age on every offer; live refresh for missing or stale
  ingredients; failures keep the old price with its real age and a warning.
- `lookup_prices` brand and Product queries.
- Household Brand Preferences in household settings (table, context, JSON
  endpoints) loaded into the Household context.
- Session Brands in the Workspace; Purchase honours Session Brand, then
  Brand Preference; a chosen brand that cannot be bought is disclosed, and
  an over-budget Purchase lists cheaper alternatives with the difference.

Out of scope: the "keep brand" UI shortcut (client), promotions, MCP
exposure of the scraper, the scraper change itself (external prerequisite).

## External prerequisite

The `ratoneando-go` scraper must expose, per price: observation time, cache
flag and currency (plus brand and package size). Tracked in
`meal_planner_api/docs/price-scraper-contract.md` and referenced from the
HTTP adapter and the PR. Until it ships, scraper items without these fields
are rejected as unusable, never assumed.

## Delivery

PR #126 was split into four chained PRs to main (strategy
`stacked-to-main`). Each slice appends its own tasks and evidence here.

1. Price scraper port with an HTTP adapter (this slice). Nothing calls it
   yet, so agent behaviour does not change.
2. Refresh stale prices live and report their age.
3. Brand and Product queries, Household Brand Preferences.
4. Purchase steered by Session Brands and Brand Preferences.

## Acceptance criteria

- [ ] Fresh prices (under 24 h) come from the database without a live call
- [ ] Missing or stale prices trigger a live lookup; failures keep the old
  price with its real age and a warning
- [ ] Brand and Product queries return matching Products with prices
- [ ] Session Brands live only in the Workspace; Brand Preferences come from
  household settings
- [ ] The agent never substitutes a chosen brand without telling the Member
- [x] Tests use a fake scraper; the scraper prerequisite is tracked and
  referenced (fake scraper in test support, contract doc, HTTP adapter)

## Tasks

- [x] S1 Price scraper client (slice 1/4, route: inline, one bounded worker
  landing a slice already written and reviewed in #126). `PriceScraper`
  behaviour, `PriceScraper.Http` reading observation time, cache flag and
  currency per price, `PriceScraper.Unavailable`, `price_scraper` wiring in
  `config/config.exs` and `config/test.exs`, `GO_SCRAPER_URL` in prod
  `config/runtime.exs` (`Http` with that URL, or `Unavailable` when unset or
  blank, never a localhost default), `:scraper_unreachable` as a transient
  read failure in `CallBounds`, the scraper contract doc and
  `PlanningAgent.FakeScraper`. Commit: the `feat(planning-agent): add the
  price scraper port with an HTTP adapter` commit on
  `feat/issue-101-part-1-price-scraper-client`.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test`
  (`config/test.exs` does not append `MIX_TEST_PARTITION` to the database
  name; `MYFOOD_TEST_DATABASE` isolates the run)
- `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix precommit`

## Progress and evidence

- S1: `PriceScraper.HttpTest` covers the contract parsing (products
  missing observation time, cache flag, currency or package size are
  dropped; a server error is `:scraper_unreachable`, a malformed body is
  invalid). `RuntimePriceScraperConfigTest` (from review round 2 of
  #126, finding R5): RED read no prod price scraper; GREEN with both cases
  (unset or blank `GO_SCRAPER_URL` gives `Unavailable`, a URL gives `Http`
  with that `base_url`). Follow-up (out of scope): `GoScraperClient`'s
  compile-time localhost default. Focused run: 8 passed.
  `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix precommit` 1240
  passed, 25 skipped (seed 892678). An earlier run had 3 order-dependent
  failures that passed on `mix test --failed` and on a full rerun; the
  first runs failed only because the shared test database still held the
  source branch's schema and lacked main's recovery migration (reset with
  `ecto.drop`, `ecto.create`, `ecto.migrate`).

## Next step

Slice 2/4: refresh stale prices live and report their age.
