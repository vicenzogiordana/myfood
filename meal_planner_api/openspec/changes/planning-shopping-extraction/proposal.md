# SDD Proposal: planning-shopping-extraction

## Change Summary

Wire shopping-cart extraction into the meal-plan confirm flow. Today, confirming
a proposal persists the weekly `scheduled_meals` but produces **no shopping
cart** — the extraction function that would build one
(`Integrations.PythonClient.extract_shopping_list/3`) has **zero call sites** in
`lib/`, and `Generation.Server.do_confirm/2` never invokes any cart logic. This
change makes confirmation also produce a persisted, tenant-scoped shopping cart
and surface it back to the client on the `proposal_confirmed` broadcast.

---

## Intent

**Problem.** A user builds a weekly plan, confirms it, and gets scheduled meals —
but the entire point downstream (buy the ingredients) is a dead end. The
extraction code exists but is orphaned and unreachable, so the product silently
delivers half of the confirm promise.

**Why now.** The tenancy refactor just landed; the persistence layer
(`shopping_items`, `checkout_sessions`) and the recipe→ingredient data model are
in place and account-scoped. This is the smallest coherent slice that turns a
confirmed plan into an actionable shopping cart.

**Success looks like.** On confirm, the system derives the cart from the recipes
already chosen in the confirmed proposal, persists it scoped to
`current_membership.account_id`, and returns a cart summary to the client — in a
single transaction with the scheduled-meal write, with no new HTTP integration.

---

## Scope

### In Scope

1. Wire cart extraction into `Generation.Server.do_confirm/2`, after
   `persist_scheduled_meals/2`, inside the same DB transaction.
2. Pure-Elixir aggregation: for each confirmed `scheduled_meal → recipe →
   recipe_ingredients`, aggregate `quantity_milli` grouped by `(ingredient_id,
   unit)`, deduped across the week.
3. Persist one `CheckoutSession` (draft) plus its `ShoppingItem` rows, scoped by
   `current_membership.account_id` (the value the server already holds as
   `state.account_id`), never `user.account_id`.
4. Surface the cart to the client: extend the `proposal_confirmed` broadcast and
   the `confirm/2` reply with `shopping_items_count` (and a small cart summary).

### Out of Scope (explicit — separate future changes)

1. **Streaming** (`slot_progress` / incremental broadcasts) — unchanged.
2. **In-chat proposal modification** — the `chat` re-optimization path is
   untouched.
3. **Retiring/deleting the orphaned `PythonClient`** — a follow-up cleanup change
   removes the Tesla/hackney HTTP client; here we simply do not call it.
4. **Extending the Port protocol** with an extract operation.
5. Supermarket assignment/grouping, price population, online checkout, delivery,
   and inventory mutation — the draft session carries none of these yet.

---

## Problem Statement

Verified against the as-built code:

- `PythonClient.extract_shopping_list/3` exists (`integrations/python_client.ex`)
  but is an HTTP `POST /api/v1/shopping-list` on an **orphaned Tesla client** that
  still references the removed `hackney` adapter. Its only test
  (`python_client_test.exs`) asserts **arity only** — it does not exercise the
  computation, so "unit-tested" overstates the coverage.
- `Generation.Server.do_confirm/2` updates the proposal to `:accepted`, persists
  `scheduled_meals`, completes the run, and broadcasts `proposal_confirmed` —
  with **no shopping-cart step**.
- The persistence layer is ready: `ShoppingItem` requires `account_id`,
  `scheduled_meal_id`, `planned_date`, `ingredient_id`, `quantity_milli`, `unit`,
  `status`; `RecipeIngredient` already carries `(ingredient_id, quantity_milli,
  unit)` per recipe. The cart is an aggregation of data the DB already owns.

---

## Key Decision — How should extraction be performed?

The extraction must resolve which mechanism produces the cart. Three options:

**(a) Extend the Port protocol** (`OptimizerServer`) with an extract operation.
Consistent with the committed Port decision, but `optimizador.py` does not own
the recipe→ingredient catalog; Elixir would have to ship that data into the Port
payload only to receive an aggregation back — redundant, and it bloats a protocol
that today only does `solve`.

**(b) Adopt the HTTP `PythonClient.extract_shopping_list/3`.** Reuses "existing"
code, but (i) resurrects an HTTP integration path the project deliberately moved
away from (`config.yaml`: optimizer is `GenServer + Port (stdio)`); (ii) the
`hackney` adapter it depends on is gone; (iii) it returns opaque `%{"items" =>
...}` JSON that **cannot** produce catalog `ingredient_id` FKs matching the
Elixir `ShoppingItem` schema, because the Python side never receives ingredient
quantities. Architecturally broken against the as-built schema.

**(c) Pure-Elixir aggregation from the confirmed proposal.** The confirmed
proposal already names the chosen recipes (`slots[].recipe_id`), and
`persist_scheduled_meals/2` already writes `scheduled_meals` with `recipe_id +
date`. From there, load each recipe's `recipe_ingredients` and aggregate
`quantity_milli` by `(ingredient_id, unit)`. No Python round-trip; the aggregation
is a simple group-and-sum, and every output field maps directly onto the
`ShoppingItem` schema.

### Recommendation: **(c) Pure-Elixir aggregation.**

The data required to build the cart — `recipe_ingredients` with `ingredient_id`,
`quantity_milli`, and `unit` — lives entirely in the Elixir DB, and those are
exactly the fields `ShoppingItem` demands. The Python extractor cannot mint
catalog FKs and would re-introduce a retired HTTP path; the Port option ships
data to Python only to get back an aggregation Elixir can compute locally. Option
(c) honors the committed Port decision (no new HTTP, no protocol bloat), keeps the
slice inside the 400-line budget, and stays within the tenancy-clean persistence
layer. The orphaned `PythonClient` is left for a separate cleanup change.

---

## Approach

1. Add a small extraction function (Application layer / a `Shopping` service or a
   private helper reachable from `do_confirm/2`) that takes the persisted
   scheduled meals and returns aggregated cart lines
   `{ingredient_id, unit, quantity_milli, planned_date, scheduled_meal_id}`.
2. In `do_confirm/2`, wrap `persist_scheduled_meals/2` + cart creation in one
   `Repo.transaction/1`: create a draft `CheckoutSession` for
   `state.account_id`, then insert `ShoppingItem` rows via
   `ShoppingRepo` (reuse `create_shopping_item/1` or `upsert_shopping_item/1`).
3. Extend the `proposal_confirmed` broadcast payload and the `{:ok, ...}` reply
   with `shopping_items_count` (and a compact summary for the client to render).
4. Follow strict TDD (RED → GREEN → TRIANGULATE): aggregation math, tenancy
   scoping, transaction atomicity, and the broadcast payload each get tests.

---

## Success Criteria

Mined from the as-built contract (and the salvageable parts of the stale
`v2-planning-spec.md`):

- [ ] `confirm` persists `scheduled_meals` **and** `shopping_items` in one
      transaction; a failure in either rolls back both.
- [ ] Every `shopping_item` is scoped to `current_membership.account_id`
      (`state.account_id`), never `user.account_id`.
- [ ] The cart aggregates ingredients across all confirmed meals, deduped by
      `(ingredient_id, unit)`, with summed `quantity_milli`.
- [ ] `proposal_confirmed` (and the `confirm/2` reply) includes
      `shopping_items_count` and a cart summary.
- [ ] A confirmed proposal with recipes that share ingredients produces a single
      merged line per `(ingredient_id, unit)`, not duplicates.
- [ ] No new HTTP integration is introduced; `PythonClient` gains no call site.
- [ ] Empty/edge input (proposal with no slots, or recipes with no ingredients)
      yields an empty cart without error.
- [ ] All new code is unit-tested (strict TDD).

---

## Open Questions (resolve in design)

1. **Aggregation grain vs. FK shape.** `ShoppingItem.scheduled_meal_id` is
   **required (not-null)**, yet `ShoppingRepo.upsert_shopping_item/1` dedups on
   `(checkout_session_id, ingredient_id)` and *replaces* (does not sum)
   `quantity_milli`. Decide the grain: per-meal rows (no cross-meal dedup) vs.
   per-session deduped rows (and, if deduped, which `scheduled_meal_id` a merged
   line references). This tension must be settled before implementation.
2. **Mixed units.** Confirm the rule for the same ingredient appearing in
   different units (expected: group by `(ingredient_id, unit)`, no conversion).
3. **`CheckoutSession.checkout_type`** is required with no default — pick the
   default for the auto-created draft (likely `:physical`).
4. **`estimated_price_cents`.** Populate from `recipe_prices`/catalog now, or
   leave `nil` for this slice (leaning `nil` to stay small).
5. **Re-confirm idempotency.** Behavior when a proposal is confirmed twice or is
   already `:accepted` (avoid duplicate carts).
