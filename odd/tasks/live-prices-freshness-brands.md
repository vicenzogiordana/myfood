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

## Acceptance criteria

- [x] Fresh prices (under 24 h) come from the database without a live call
- [x] Missing or stale prices trigger a live lookup; failures keep the old
  price with its real age and a warning
- [x] Brand and Product queries return matching Products with prices
- [x] Session Brands live only in the Workspace; Brand Preferences come from
  household settings
- [x] The agent never substitutes a chosen brand without telling the Member
- [x] Tests use a fake scraper; the scraper prerequisite is tracked and
  referenced

## Tasks

- [x] T1 Freshness, live refresh through the scraper port, failure keeps the
  old price with its age (route: inline, single bounded worker owning the
  whole issue). Commit: the `feat(planning-agent): refresh stale prices ...`
  commit on this branch.
- [x] T2 Brand and Product queries in `lookup_prices` (route: inline).
  Commit: the `feat(planning-agent): query prices by brand and Product`
  commit on this branch.
- [x] T3 Household Brand Preferences in settings and the Household context
  (route: inline). Commit: the `feat(settings): add Household Brand
  Preferences` commit on this branch.
- [x] T4 Session Brands in the Workspace, brand-steered Purchase, disclosed
  substitutions and budget alternatives (route: inline). Commit: the
  `feat(planning-agent): steer the Purchase with Session Brands ...` commit
  on this branch.

## Checks

- `MIX_TEST_PARTITION=101 MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test`
  (`config/test.exs` does not append `MIX_TEST_PARTITION` to the database
  name; `MYFOOD_TEST_DATABASE` isolates the run)
- `mix precommit`

## Progress and evidence

- T1: RED observed for 8 of 9 `LivePricesTest` session tests (the unknown
  ingredient test already held); GREEN after the scraper port, freshness and
  live refresh. `PriceScraper.HttpTest` covers the contract parsing.
  `PurchaseToolsTest` now pins its clock (fixture prices were aged by the
  real clock). Planning agent suite: 154 passed.
- T2: RED observed for 6 brand and Product query session tests; GREEN after
  brand and product filters (freshness judged on the matching offers).
  Planning agent suite: 160 passed.
- T3: RED observed for 7 controller tests and 2 session tests (missing
  module and routes); GREEN after the table, context, controller and the
  Household context line in the instructions.
- T4: RED observed for 9 of 11 `BrandsTest` session tests; GREEN after the
  `set_session_brand` tool, Workspace `session_brands`, the
  `session_brand_changed` event and brand-steered Purchase lines. The
  rejection test was reshaped because three rejected calls in a row hit the
  no-progress limit before present_proposal (expected behaviour).
  Planning agent and web suites: 487 passed. Full suite (partition 101):
  first `mix precommit` run had 3 failures in the untouched
  `PlanningCandidateBuilderTest` (`plan_not_found` from its own setup);
  the same seed (490195) and a fresh seed both pass 1141/1141 (25 skipped),
  so it is an order-dependent flake outside this change.

## Next step

Push the branch and open the PR; review gate (Jorge el Curioso) runs separately.
