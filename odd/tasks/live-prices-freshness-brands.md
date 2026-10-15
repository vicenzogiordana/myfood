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

## Review round 1 (Jorge el Curioso, PR #126)

Route: inline (one source file plus tests, findings already mapped).

- [x] R1 Product search scraped an unbounded number of Ingredients
  (CD-1, SP-1). `Prices.lookup/2` now caps the merged Ingredient set at
  `Prices.max_ingredients/0` (50, named Ingredients first), the Product
  query itself is limited, and the returned offers are capped at
  `Prices.max_offers/0` (200). RED: `PricesTest` with 60 stale Ingredients
  matching one Product query saw 60 refresh calls (cap 50); GREEN after the
  cap.
- [x] R2 `Prices.record/2` raised inside the read tool (CD-2, TR-1, SP-2).
  It now returns `:ok | {:error, :record_failed}` (all or nothing), the
  Product insert uses `on_conflict: :nothing` plus a re-read, as the
  Supermarket insert already did, and `refresh_all` turns a failed record
  into a `refresh_failed` warning. RED: a 300-character product name raised
  `Postgrex.Error` (varchar 255) and a zero package quantity raised
  `Ecto.InvalidChangesetError`; GREEN with `PricesTest` record tests and the
  `LivePricesTest` session test asserting a `refresh_failed` warning. The
  concurrent-insert race itself is not reproducible deterministically in a
  test; the reuse path is covered by an idempotent re-record test.
  `Http.item/1` was left unchanged (optional in the contract).
- Checks: `MIX_TEST_PARTITION=101 MYFOOD_TEST_DATABASE=meal_planner_api_test101
  mix test` 1146 passed, 25 skipped; `mix precommit` 1146 passed, 25 skipped.

## Review round 2 (Jorge el Curioso, PR #126)

Route: inline (findings already mapped with repair contracts; three small
source edits plus tests). Caps stay per Planning Session and count only
OpenAI model calls; scraper calls remain read calls under `CallBounds`.

- [x] R3 No refresh memo: a stale or unmatched Ingredient was re-scraped on
  every `lookup_prices` (CD-1, TR-3, SP-1). `Prices.lookup/2` takes and
  returns a `refresh_memo` (ingredient id => attempt time and failure); an
  Ingredient refreshed in the last 15 minutes is not scraped again and its
  `refresh_failed` or `still_stale` warning is reported again. The memo
  lives in the Workspace (`price_refreshes`). RED: `LivePricesTest` "refresh
  memo" saw 2 scrapes for one 30-hour-old Ingredient answered `{:ok, []}`,
  2 for a failed refresh, and 6 for brand `zzz` on 3 Ingredients; GREEN: 1,
  1 and 3.
- [x] R4 `session_brand_changed` was shown but lost when the turn was cut by
  the deadline (TR-1). `set_session_brand` now checkpoints the Workspace
  (`{:workspace, ref, ws}`, like the allowance checkpoint), and `stop_turn`
  adopts the latest one. RED: `BrandsTest` with a slow model step after
  `set_session_brand` and a 300 ms deadline found no Session Brand in the
  session state after `limit_reached` time; GREEN after the checkpoint.
- [x] R5 Production silently targeted `http://localhost:3000` (SP-2).
  `config/runtime.exs` (prod) sets the planning agent price scraper to
  `{Http, base_url: GO_SCRAPER_URL}`, or `Unavailable` when it is unset or
  blank. The URL goes in the adapter options rather than `:go_scraper_url`,
  which `GoScraperClient` reads with `compile_env`. RED:
  `RuntimePriceScraperConfigTest` read no prod price scraper; GREEN with
  both cases. Follow-up (out of scope): `GoScraperClient`'s compile-time
  localhost default.
- Checks: `MIX_TEST_PARTITION=101 MYFOOD_TEST_DATABASE=meal_planner_api_test101
  mix precommit` (compile with warnings as errors, format, full test suite)
  1152 passed, 25 skipped. Note: `config/test.exs` does not append
  `MIX_TEST_PARTITION` to the database name; isolation comes from
  `MYFOOD_TEST_DATABASE`.

## Review round 3 (Jorge el Curioso, PR #126)

Route: inline (two mapped findings, one source file plus its tests). The
per-session cap of OpenAI model calls stays as is; these fixes only bound
scraper calls inside one lookup.

- [x] R6 No per-lookup circuit breaker; never-attempted Ingredients were
  memoized as failed. `refresh_all` stops scraping the rest of the lookup
  after the first `:scraper_timeout`, `:scraper_unreachable` or
  `:deadline_exceeded`, giving the remaining Ingredients that reason as a
  `refresh_failed` warning. Skipped Ingredients and every
  `:deadline_exceeded` stay out of `refresh_memo`, so the next lookup
  retries them. RED: `PricesTest` "when the scraper is down" saw 5 scrapes
  for 5 Ingredients per reason, and a follow-up lookup scraped 0 of the 2
  skipped; GREEN: 1 scrape, memo size 1 (0 for a deadline), 2 retries.
- [x] R7 Silent truncation at `max_offers/0`. Offers are now taken
  round-robin from each Ingredient's cheapest, so every Ingredient with
  offers keeps some, and an Ingredient that lost offers gets an
  `:offers_truncated` warning (which makes the tool outcome `partial`).
  RED: 5 Ingredients x 100 offers returned no `offers_truncated` warning
  (the global take keeps only the first 2 Ingredients' offers); GREEN: 200 offers,
  each Ingredient's cheapest kept, each flagged.
- Checks: `MIX_TEST_PARTITION=101 MYFOOD_TEST_DATABASE=meal_planner_api_test101
  mix test` 1157 passed, 25 skipped; `mix precommit` same result.

## Next step

Review gate (Jorge el Curioso) re-runs separately on the updated PR.
