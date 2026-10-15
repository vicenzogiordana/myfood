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

1. Price scraper port with an HTTP adapter (#132). Nothing calls it yet,
   so agent behaviour does not change.
2. Refresh stale prices live and report their age (#133). Lookups take
   Ingredient names only; brand and Product filters come in slice 3.
3. Brand and Product queries, Household Brand Preferences (this slice).
   Brand Preferences reach the agent's instructions only; they do not
   change the Purchase until slice 4.
4. Purchase steered by Session Brands and Brand Preferences.

## Acceptance criteria

- [x] Fresh prices (under 24 h) come from the database without a live call
- [x] Missing or stale prices trigger a live lookup; failures keep the old
  price with its real age and a warning
- [x] Brand and Product queries return matching Products with prices
- [ ] Session Brands live only in the Workspace; Brand Preferences come from
  household settings (Brand Preferences half done in slice 3; Session
  Brands come in slice 4)
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
- [x] S2 Live refresh and price age (slice 2/4, route: inline, one bounded
  worker landing a slice already written and reviewed in #126, rebuilt from
  its final head with the brand and Product code left out).
  `Prices.lookup/2` (names only) reads the database first and refreshes a
  missing Ingredient, or one with an offer 24 h old or older, through the
  scraper port, recording the scraper's own observation time; a failed
  refresh records nothing and adds a `refresh_failed` warning, a refresh
  that brings only old data adds `still_stale`. Review hardening from #126
  rounds 1-3 kept: Ingredient cap (`max_ingredients/0`, 50) and offer cap
  (`max_offers/0`, 200, round-robin from each Ingredient's cheapest with
  an `offers_truncated` warning), `record/2` (now `record/3`) returning
  `{:error, :record_failed}` instead of raising, a 15-minute refresh memo,
  and a circuit break after `:scraper_timeout`, `:scraper_unreachable` or
  `:deadline_exceeded`. `lookup_prices` returns prices with `age_hours`
  and `fresh`, `missing` and `warnings`. Purchase lines carry the age of
  their price, `stale_prices` lists stale lines and the Proposal budget is
  `uncertain` when any line is stale. Session options `:price_scraper`
  and `:clock`. Commit: the `feat(planning-agent): refresh stale prices
  live and report their age` commit on
  `feat/issue-101-part-2-live-price-refresh`.
- [x] S3 Brand and Product queries, Household Brand Preferences (slice 3/4,
  route: inline, one bounded worker landing a slice already written and
  reviewed in #126, ported onto main's slice-2 code). `Prices.lookup/2`
  takes `:brand` (case-insensitive exact match on the Product brand) and
  `:product` (case-insensitive substring of the Product name or brand;
  without names it searches every stored Product, wildcards matched
  literally). Freshness is judged on the matching offers, so a brand the
  database lacks is looked up live; a brand or Product nobody sells is
  `missing` with `no_matching_brand` or `no_matching_product`, never
  priced. `Prices.stored_brand/2` validates a brand against stored
  Products. `lookup_prices` gains the optional `brand` and `product`
  parameters (`ingredients` is no longer required when `product` is
  given). Household Brand Preferences: `household_brand_preferences`
  table (one per Household and Ingredient, non-blank brand),
  `BrandPreferences` context, `GET/PUT/DELETE
  /settings/brand-preferences[/:ingredient_id]` for any active Member,
  and `HouseholdContext` renders them into the agent's instructions; another
  Household's preferences never reach the session. Commits on
  `feat/issue-101-part-3-brand-product-queries-and-preferences`:
  `feat(settings): add Household Brand Preferences` (fbf6b05) and
  `feat(planning-agent): query prices by brand and Product`.

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
- S1 review round (Jorge el Curioso on PR #132), route: inline, two
  confirmed findings in `PriceScraper.Http`:
  - Non-string `observedAt` crashed `fetch/2` (`FunctionClauseError` in
    `DateTime.from_iso8601/1`). RED: the new test with `observedAt` nil
    and `1_700_000_000` raised. GREEN: `is_binary(observed_at)` in the
    `item/1` guard; the bad products are dropped and the valid one kept.
  - Every non-200 status was the transient `:scraper_unreachable`, so a
    permanent 4xx was retried. RED: a 404 gave `:scraper_unreachable`.
    GREEN: 5xx and 429 stay `:scraper_unreachable`; any other status is
    the non-transient `:scraper_rejected` (not in `CallBounds` transient
    reads).
  - Focused run: 8 passed.
    `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix precommit` 1242
    passed, 25 skipped.

- S2 glue for main (which changed after #126 was cut):
  - The refresh memo is a `price_refreshes` field of the `Workspace`
    struct. Main's Session already checkpoints the Workspace after every
    tool call (`on_workspace`) and snapshots it for restart recovery, so
    the memo survives a cut turn and a restart without the source branch's
    separate `report_workspace` checkpoint.
  - Budget certainty lives in `Proposal.build/2` on main, so the stale
    check (`Purchase.stale?/1`) is there, and prices are aged at the
    context's `:clock` (the Session passes it at present and at confirm).
  - Confirmation rebuilds the Proposal and compares content. A price's
    `age_hours` ticks with the clock, so `Proposal.same_content?/2` ignores
    it; a price turning stale still changes the content (its `fresh` flag
    and the budget's `uncertain`). Test: `LivePricesTest` "a price that
    only got older is the same Proposal content; one turned stale is not".
  - The cap test of #126 used a Product query; here it is a name-only
    lookup of 60 stale Ingredients (exactly 50 refreshed, 50 warnings).
- S2 evidence: `LivePricesTest` (fresh, stale, missing, refresh memo,
  present_proposal) 13 passed; `PricesTest` (scraper down, offer cap,
  Ingredient cap, `record/2`) and `PurchaseToolsTest` (clock pinned so
  fixture prices are fresh; without it two budget assertions read
  `uncertain: true`, observed) pass. Full
  `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1275 passed,
  25 skipped before the Proposal content test was added;
  `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix precommit` (compile
  with warnings as errors, format, full suite) 1276 passed, 25 skipped.
- S2 review round (Jorge el Curioso on PR #133), route: inline, one
  confirmed finding in `Prices`:
  - A future-dated scraper `observedAt` was stored unchecked; `with_age`
    clamped its age to 0, so it read as fresh and, being the latest
    observation of its Product, shadowed later real ones. RED: `record/3`
    accepted an item dated `now + 3 days`, and a lookup scraping one
    returned it fresh with no warning. GREEN: `Prices.record/3` (new `now`
    argument, threaded from the lookup's `now`) rejects the whole scrape
    with `{:error, :record_failed}` when any item is dated more than 5
    minutes after `now`; the lookup reports `refresh_failed`, and a later
    real observation is recorded and returned fresh. An item 60 s ahead is
    accepted (clock skew).
  - Focused `PricesTest` 12 passed.
    `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1279 passed,
    25 skipped; `mix precommit` 1279 passed, 25 skipped.
- S2 review round 2 (Jorge el Curioso on PR #133), route: inline, one
  confirmed low-severity finding in `Prices`:
  - `product!/3` overwrote a stored `Product.brand` with `nil` when a later
    scrape omitted the brand, losing input for slice-3 Brand Preferences.
    RED: recording an item with brand "Acme" and then the same key with
    brand `nil` left the stored brand `nil`. GREEN: `product!/3` keeps the
    stored brand when the scraped brand is `nil`; a different non-nil brand
    still replaces it ("Globex").
  - Focused `PricesTest` 13 passed. `MYFOOD_TEST_DATABASE=meal_planner_api_test101
    mix precommit` (compile with warnings as errors, format, full suite)
    1280 passed, 25 skipped.

- S3 glue for main:
  - The migration is `202610151400000_create_household_brand_preferences`
    (15 digits, after main's `202610141095000`); the source branch's
    14-digit `20261015140000` would sort before main's latest migration.
  - Main keeps slice 2's review fixes (future-dated scrape rejection,
    `record/3`, a scrape without a brand keeping the stored one); the
    brand and Product filters were added on top of them.
  - `PricesTest` keeps slice 2's name-only cap test and adds the Product
    query cap test of #126 (60 stale matching Ingredients, exactly 50
    refreshed, 50 warnings).
  - The Brand Preferences instruction line and the `BrandPreferences`
    moduledoc describe slice-3 behaviour only (disclosed to the agent, no
    effect on the Purchase); the Brands rules and `set_session_brand` stay
    for slice 4.
- S3 evidence: focused `BrandsTest` (Household Brand Preferences),
  `LivePricesTest` (brand and product queries, brand-miss memo),
  `PricesTest` and `HouseholdBrandPreferenceControllerTest` 43 passed.
  Full `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1297
  passed, 25 skipped; `mix precommit` (compile with warnings as errors,
  format, full suite) 1297 passed, 25 skipped. The shared test database
  needed `mix ecto.migrate` for the new table first.
- S3 review round (Jorge el Curioso on PR #134), route: inline, one
  confirmed low-severity finding in `Tools`:
  - A whitespace-only `product` passed `string_arg/2`, so `lookup_prices`
    skipped the `ingredients_required` guard and `Prices.normalize/1`
    trimmed it to nil: an empty result with no error. RED: `lookup_prices`
    with `%{"product" => "  "}` and with `%{"ingredients" => [],
    "product" => "\n"}` returned empty prices instead of the error (2
    failures). GREEN: `run("lookup_prices")` reads `product` and `brand`
    through a new `trimmed_arg/2` that maps blank to nil; `string_arg/2`
    and `Prices.lookup` are unchanged.
  - Focused `PurchaseToolsTest` 16 passed.
    `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1299 passed,
    25 skipped; `mix precommit` 1299 passed, 25 skipped.

## Next step

Slice 4/4: Purchase steered by Session Brands and Brand Preferences.
