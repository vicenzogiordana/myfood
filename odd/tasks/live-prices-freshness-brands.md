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
   Ingredient names only; brand and Product filters come later.

The rest of #126 (an earlier combined attempt, #134, went through four
review rounds) is split into three more slices:

3. Household Brand Preferences settings (#135). Disclosed to the agent
   with neutral wording; they do not change the Purchase yet.
4. Brand and Product price queries (#136).
5. Purchase steered by Session Brands and Brand Preferences (this slice).

## Acceptance criteria

- [x] Fresh prices (under 24 h) come from the database without a live call
- [x] Missing or stale prices trigger a live lookup; failures keep the old
  price with its real age and a warning
- [x] Brand and Product queries return matching Products with prices
- [x] Session Brands live only in the Workspace; Brand Preferences come from
  household settings
- [x] The agent never substitutes a chosen brand without telling the Member
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
- [x] S3 Household Brand Preferences settings (split slice 1/3, route:
  inline, one bounded worker landing code already written and reviewed in
  #126 and #134). `household_brand_preferences` table (one brand per
  Household and Ingredient), `BrandPreferences` context, `GET`, `PUT` and
  `DELETE /api/accounts/:account_id/settings/brand-preferences[/:ingredient_id]`
  for any active Member, scoped to the current membership (another
  Household can never read or change them). `HouseholdContext` loads them
  and lists them in the instructions as "Brand Preferences from household
  settings"; they do not affect the Purchase in this slice. Review fixes
  from #134 kept: a 14-digit migration version that sorts after main's
  latest (`20261015170000`), and brands stored as a single line (whitespace
  runs collapsed, control characters rejected with 422, collapsed again in
  the instructions) so a brand cannot forge instruction lines. Commit: the
  `feat(households): add Household Brand Preferences settings` commit on
  `feat/issue-101-part-4-household-brand-preferences`.
- [x] S4 Brand and Product price queries (split slice 2/3, route: inline,
  one bounded worker landing code already written and reviewed in #126 and
  #134, applied by hand onto main's `Prices` so the S2 review fixes stay;
  reworked to the settled contract below after three Jorge rounds on #136).
  Settled `lookup_prices` contract (product decision 2026-10-19):
  `ingredients` is required (schema `required`, tool description); a call
  without names, or with only blank names, returns `ingredients_required`
  with a reason asking for the names, and there is no catalog-wide Product
  search. Optional `brand` (case-insensitive exact match) and `product`
  (case-insensitive substring of the Product name, matched literally) only
  narrow the named Ingredients' offers and combine with AND. An Ingredient
  is refreshed live when it has no offer, any stale offer (freshness is
  judged on all its offers, because the scrape is keyed by Ingredient
  name) or, with a brand, no stored offer of that brand. Filters apply
  before the caps: at most 50 names are looked up (the first given; the
  rest get `ingredients_truncated` warnings and are not reported missing)
  and at most 200 offers returned (round-robin, `offers_truncated`);
  `truncated` is true when either cap cut the result. A `missing` entry
  names the Ingredient plus every filter asked, with reason
  `unknown_ingredient`, `no_stored_price` or `no_matching_offer` (replacing
  `no_matching_brand` and `no_matching_product`, which blamed one filter).
  `Prices.stored_brand/2` (the stored spelling of a brand for an
  Ingredient) is kept for the next slice. Commits: `ad50c77` and the
  contract rework commit on
  `feat/issue-101-part-5-brand-product-price-queries`.
- [x] S5 Purchase steered by Session Brands and Brand Preferences (split
  slice 3/3, route: inline, one bounded worker landing code already
  written and reviewed in #126, applied by hand onto main because main's
  Session, Workspace and Proposal changed after #126 was cut).
  `Purchase.for_meals/4` takes a `:brands` option (chosen brand per
  Ingredient id): with no brand the cheapest Product is bought; a chosen
  brand is bought whenever a usable Product of it exists, even when another
  brand is cheaper, and the line carries `brand_choice` and
  `cheaper_alternative` with the difference; a chosen brand that cannot be
  bought falls back to the cheapest Product and is listed in
  `brand_substitutions`, never swapped silently. `Proposal.brand_choices/1`
  merges the Household's Brand Preferences with the Session Brands (a
  Session Brand wins) and `Proposal.build/2` passes them, so confirmation
  rebuilds the Proposal with the same brands (the Session passes its
  Session Brands in the confirm context). `set_session_brand` sets or
  clears a Session Brand in the Workspace (`session_brands` field; never
  household settings), accepts only a brand a stored Product of the
  Ingredient has (`Prices.ingredient_by_name/1`, `Prices.stored_brand/2`),
  checkpoints the Workspace through the tool context's `report_workspace`
  before emitting `session_brand_changed`, and so survives a turn cut by
  the deadline. `present_proposal` returns `brand_substitutions` and, only
  when the Purchase breaks the budget, `brand_alternatives` with their
  price difference for the agent to offer. The never-swap rule and the
  `set_session_brand` rule are in the agent instructions ("Brands:") and in
  `docs/CHANNELS.md` ("Brands"). Builds on main's settled `lookup_prices`
  contract from #136 unchanged. Commit: the `feat(planning-agent): steer
  the Purchase with Session Brands and Brand Preferences` commit on
  `feat/issue-101-part-6-session-brands-purchase-steering`.

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
  - Focused `PricesTest` 13 passed. `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix precommit`
  (compile with warnings as errors, format, full suite) 1291 passed, 25
  skipped. `MYFOOD_TEST_DATABASE=meal_planner_api_test101
    mix precommit` (compile with warnings as errors, format, full suite)
    1280 passed, 25 skipped.

- S3 evidence: `HouseholdBrandPreferenceControllerTest` (CRUD, tenancy,
  single-line storage, 422 on a control character), `BrandsTest`
  ("Household Brand Preferences": they reach the instructions, and another
  Household's never do) and `HouseholdContextTest` (a brand with line
  breaks cannot forge instruction lines): 13 passed. `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix precommit`
  (compile with warnings as errors, format, full suite) 1291 passed, 25
  skipped.
- S3 review round (Jorge el Curioso on PR #135), route: inline, one
  confirmed low-severity finding in `HouseholdBrandPreference`:
  - `validate_length(:brand, max: 120)` counted graphemes while the
    `varchar(255)` column counts codepoints, so "a" followed by 300
    combining acute accents (one grapheme) passed the changeset and raised
    `string_data_right_truncation` (a 500 instead of a 422), and shorter
    combining-mark runs exceeded the intended 120 bound. RED: the new
    controller test got `Postgrex.Error` on that PUT. GREEN: the length
    check uses `count: :codepoints`; the combining-mark brand and a
    121-character ASCII brand return 422 with a `brand` error, and a
    120-character brand is still accepted.
  - Focused `HouseholdBrandPreferenceControllerTest` 9 passed.
    `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1292 passed,
    25 skipped; `mix precommit` 1292 passed, 25 skipped.

- S4 evidence: `LivePricesTest` "brand and product queries" (brand
  filter, brand missing from fresh prices without a live call, brand
  missing from stale prices looked up live, brand nobody sells, Product
  query across names and brands, Product plus brand, Product matching
  nothing and literal `%`) and "refresh memo" (a brand query that matches
  nothing scrapes each Ingredient once); `PricesTest` "lookup/2 with a
  Product query" (at most 50 stale matching Ingredients refreshed) and
  "lookup/2 with a brand query" (fresh offers of another brand not
  refreshed, stale ones refreshed); `PurchaseToolsTest` (blank `product`
  requires ingredients). Focused run: 53 passed.
  `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1305 passed,
  25 skipped; `mix precommit` (compile with warnings as errors, format,
  full suite) 1305 passed, 25 skipped.
- S4 review round (Jorge el Curioso on PR #136), route: inline, one
  confirmed medium-severity finding in `Prices.lookup/2`:
  - With names and `product` both set, the looked-up Ingredients were the
    named ones plus every Ingredient with a matching Product, so
    `ingredients: ["milk"], product: "Acme"` scraped and returned other
    Ingredients' Acme offers and used up the Ingredient and offer caps.
    RED: the new `PricesTest` "with names narrows the named Ingredients
    instead of adding others" refreshed both Milk and Rice. GREEN: the
    Product search over every stored Product runs only without names;
    with names the Product query only filters their offers.
  - Focused `PricesTest` + `LivePricesTest` 38 passed.
    `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1306 passed,
    25 skipped; `mix precommit` 1306 passed, 25 skipped (one earlier
    precommit run had one failure that did not reproduce on two reruns;
    it was logged next to a "session lost its lock" warning, outside this
    change).
- S4 review round 2 (Jorge el Curioso on PR #136), route: inline, one
  confirmed medium-severity finding in `Prices.lookup/2`:
  - A Product search without names took the first 50 Ingredients by name
    before the brand filter, and silently: with more than 50 matching
    Ingredients, a branded one sorted past the 50th was never looked up
    (`no_matching_product` for a Product that exists) and up to 50
    Ingredients of other brands were scraped. RED: `PricesTest` "with a
    brand finds the branded Ingredient past the lookup cap" (56 matching
    Ingredients, the brand only on the last) returned no prices, and the
    60-Ingredient search had no `:ingredients_truncated` warning. GREEN:
    the search applies the brand (case-insensitive, as `brand_match?/2`)
    in SQL before the cap, fetches cap + 1 rows, and adds
    `%{ingredient: nil, reason: :ingredients_truncated}` when more matched;
    exactly 50 matching Ingredients add no warning.
  - Focused `PricesTest` 19 passed.
    `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1308 passed,
    25 skipped; `mix precommit` 1308 passed, 25 skipped.
- S4 review round 3 (Jorge el Curioso on PR #136), route: inline, one
  confirmed low-severity finding in `Prices.lookup/2`:
  - A named lookup with both a brand and a Product that matched nothing was
    always reported as `:no_matching_brand`, even when the brand was stored
    and only the Product text failed. RED: `PricesTest` "with a Product of a
    stored brand blames the Product, not the brand" (milk, Product "Whole"
    of brand Acme, lookup brand Acme + product "skimmed") got
    `:no_matching_brand`. GREEN: `named_gap/5` checks, when both are set,
    whether any offer passes the brand filter alone; if so it reports
    `:no_matching_product` with the brand and Product, else
    `:no_matching_brand` as before.
  - Focused `PricesTest` 20 passed.
    `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1309 passed,
    25 skipped; `mix precommit` 1309 passed, 25 skipped.

- S4 contract rework (settled design, 2026-10-19), route: inline, one
  bounded worker. Resolves the confirmed Jorge findings on #136: union of
  unrelated Ingredients, the silent 50-Ingredient cap of the nameless
  search, the brand blamed for a combined miss, and the brand dropped from
  a nameless miss. RED: 17 failures across `PricesTest`, `LivePricesTest`
  and `PurchaseToolsTest` (brand-only, product-only and blank-name calls
  not rejected, schema without `required`, fresh offers of another brand
  not looked up live, `no_matching_brand` instead of `no_matching_offer`,
  combined miss missing a filter, Product text matching the brand, no
  `truncated` key, names past the cap reported `no_stored_price`). GREEN:
  focused run 65 passed; `MYFOOD_TEST_DATABASE=meal_planner_api_test101
  mix precommit` (compile with warnings as errors, format, full suite)
  1317 passed, 25 skipped. Removed with the nameless mode: the Product
  search over every stored Product, its `ingredients_truncated` warning
  with a `nil` Ingredient, its `no_matching_product` miss and their tests.

- S5 glue for main: the Session already checkpoints the Workspace after
  every tool call (`on_workspace`); `set_session_brand` also checkpoints
  through `report_workspace` in the tool context before the Member sees the
  change, so a deadline cut between the event and the tool's return cannot
  lose it. `session_brands` is read with a default so a Workspace restored
  from an older snapshot still works. Purchase keeps main's Recipe Draft
  needs (`drafts` argument).
- S5 evidence: `BrandsTest` "Purchase with brands" (cheapest without a
  brand, Brand Preference honoured over a cheaper brand with the
  alternative named, Session Brand overriding the preference visibly and
  leaving household settings untouched, Session Brand discarded with its
  Planning Session, clearing falls back to the preference visibly,
  unbuyable chosen brand listed in `brand_substitutions`, budget conflict
  answered with `brand_alternatives`, none within budget) and
  "set_session_brand" (unknown ingredient, unknown brand and blank brand
  rejected; a Session Brand survives a turn cut by the deadline): 12
  passed. `MYFOOD_TEST_DATABASE=meal_planner_api_test101 mix test` 1327
  passed, 25 skipped; `mix precommit` (compile with warnings as errors, format, full
  suite) 1327 passed, 25 skipped.

## Next step

Review of the S5 PR; with it merged, #101 is complete.
