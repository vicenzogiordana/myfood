# Exploration: shopping-derived-from-confirmed-plan

> **Change**: `shopping-derived-from-confirmed-plan` — implement the cart rebuild, net-shortage math, capability gate, and provenance invariant required by issue #36 (parent spec #29 stories 14–17).
> **GitHub issue**: #36 (parent #29; blocked by #30 / #33 / #34 / #35 — all merged to `main` via PRs #53–#57, #61–#65, #66–#68, #69–#71).
> **Artifacts**: this file + sibling `proposal.md` / `design.md` / `specs/*.md` / `tasks.md` (next phases).
> **OpenSpec preflight**: artifact store `hybrid` (OpenSpec files + Engram), pace `interactive`, review budget 400 lines, delivery `ask-on-risk`, chain `stacked-to-main`, **strict TDD**.

> **CodeGraph status**: the project's `.codegraph/` index only covers the Python optimizer (`5 files`, `0.23 MB`). Investigation fell back to direct `Read`/`Grep` for Elixir sources (the layered webapp). Per the CodeGraph protocol this fallback is allowed when the index doesn't cover the relevant files; nothing in the codebase had to be indexed to answer the brief.

---

## Current State

### Cart already exists — but it's "raw recipe quantities from one proposal", not "net-shortage from the full active plan"

The cart writes that PR #16 / #18 (`planning-shopping-extraction`) landed on `main` are present, atomic with confirm, and scoped to `state.account_id`. But they don't satisfy #36's contract — three gaps:

1. **No inventory subtraction.** `Generation.Server.persist_shopping_cart/2` (`lib/meal_planner_api/generation/server.ex:728`) writes `quantity_milli: line.quantity_milli` straight from `RecipeRepo.list_ingredients_for_recipes/1` + `GenerationService.build_cart_lines/2`. The recipe tells you 200 g of flour; the cart records 200 g even if 200 g of flour is already in the fridge. Spec #29 story 16 ("shortages normalized and exact, without package rounding") requires the cart to be `needed − usable_inventory`, not the raw recipe total.
2. **One proposal, not the full active plan.** `persist_shopping_cart/2` consumes the `scheduled_meals` that the same `Multi` step just wrote (`persist_scheduled_meals/2`) — i.e. only THIS proposal's slots. Spec #29 story 14 says "exactly one shopping list rebuilt from the full resulting active plan" — across every confirmed `scheduled_meal` for `(account_id, range)`, including meals that pre-existed in the window (range-replacement PR #35 preserves outside-range meals but does not touch the cart).
3. **No capability gate on the shopping list.** The HTTP `/api/shopping-list` route is wired through the `:enforce_capability` pipeline (`router.ex:177,196`) — but only when `:revenuecat_access_enforcement` is **enabled** (off by default, `enforce_capability.ex:11–17`). Spec #29 / #36 AC #1 demands an explicit flag-on runtime proof, mirroring the calendar PR2 pattern.

### The seams needed already exist

- **Atomic transaction window** is the `Ecto.Multi` inside `Generation.Server.run_confirm_transaction/3` (`generation/server.ex:392–420`). Order today is `mark_committed → accept_proposal → scheduled_meals → shopping_cart`. The `shopping_cart` step is the exact insertion point.
- **Active-plan window** is `{range_from, range_to}` on the `PlanningSession` row — already loaded inside `mark_committed/3` via `SELECT … FOR UPDATE` (`data/planning_repo.ex:462–480`). No new schema, no new query, no race window.
- **Usable inventory (subtracts future reservations)** is `MealPlannerApi.Inventory.available_for/2` (`lib/meal_planner_api/inventory.ex:14–32`). It already implements "physical stock minus reservations from other uncooked future meals" — the `usable inventory` predicate spec #29 story 16 needs. `ShoppingCheckout.sync_from_planning/4` (`shopping_checkout.ex:245–296`) uses exactly this pattern (greedy pool) and is the closest prior art.
- **Capability gate** uses `MealPlannerApi.AccountAccess.eligible?/1` (`account_access.ex`) over half-open trial + entitlement windows, mirrored in `MealPlannerApiWeb.ChannelCapability.authorize/1` and `MealPlannerApiWeb.Plugs.EnforceCapability`. `PlanningChannel.check_handler_entitlement/1` (`planning_channel.ex:428–434`) is the proven pattern for per-handler re-check.
- **Realtime topic** is `"planning:#{state.account_id}"`. `Server.broadcast/3` (`generation/server.ex:631–652`) already uses `Phoenix.Channel.Server.broadcast!/4` on that topic.

### What does NOT exist (and is NOT in #36's scope)

Stories 18–21 of spec #29 — reservation lifecycle (`available → reserved_in_cart → purchased`), 1-hour expiry, actual-quantity purchase confirmation with remainder return, idempotent purchases — are **future changes**, not #36. The current `ShoppingItem.status` enum (`pending | in_cart | pending_delivery | checked_out | archived`, CHECK constraint at `20260323102000`) has no `reserved_in_cart` or `purchased` value, no `expires_at` column, no separate `cart_reservations` table. Confirmed by searching `lib/meal_planner_api/persistence/**` for `Reservation|InventoryMovement|CartReservation` — only matches are the existing `inventory_mutation_events.trigger_type = :purchase` audit row and the unused `:pending_delivery` flow. #36 must call this out explicitly in the proposal so the user knows what's deferred.

### Schema / migration state

- No `shopping_items` migration in 2026 (only the original `20260322093000` and the `202606070000000_add_checkout_session_to_shopping_items`).
- The stale `planning-shopping-extraction` work landed with **no migration** (its design.md §10 says "No migration required. Additive to the confirm flow; existing `proposal_confirmed` consumers ignore new payload keys."). Same posture is correct for #36.
- No mismatch between `ShoppingItem` Ecto.Enum and the DB CHECK after migration `20260323102000` (`:pending_delivery` is in both).

---

## Affected Areas

- `meal_planner_api/lib/meal_planner_api/generation/server.ex` — `persist_shopping_cart/2` (line 728) and `insert_cart_items/2` (line 754) are the production seam. Replace with a `:rebuild_shopping_cart` step that (a) reads `session.range_from/range_to`, (b) calls `Inventory.available_for/2`, (c) wipes existing pending/in_cart items in the window, (d) inserts per-meal `ShoppingItem` rows carrying the **net** shortage. Renamed/replaced, not removed; tests cover the swap.
- `meal_planner_api/lib/meal_planner_api/services/generation_service.ex` — extend `build_cart_lines/2` (or split into a new `Services.ShoppingRebuilder.compute_net_shortages/2`) to accept an available-pool parameter and subtract greedily. Pure function; reusable in tests without DB.
- `meal_planner_api/lib/meal_planner_api/data/shopping_repo.ex` — add `delete_pending_for_window/2` (data layer; `Repo.delete_all` scoped to `(account_id, planned_date ∈ range, status ∈ (:pending, :in_cart))`). Preserves `:checked_out` and `:archived`.
- `meal_planner_api/lib/meal_planner_api/services/shopping_service.ex` — `ensure_shopping_items_from_schedule/3` (line 112) becomes redundant for the confirm path; keep for the `GET /api/shopping-list` fallback but add a docstring note pointing to the new rebuilder as the source of truth post-confirm.
- `meal_planner_api/lib/meal_planner_api/shopping_checkout.ex` — `sync_from_planning/4` (line 245) is the prior-art implementation of the net-shortage math. Refactor opportunity (extract the per-meal loop into a pure function `ShoppingCheckout.compute_net_shortages/2` so both the HTTP `GET` path and the new confirm path share one source of truth for the math). Marked as a possible cleanup in PR2; do not block the AC on it.
- `meal_planner_api/lib/meal_planner_api_web/controllers/shopping_controller.ex` — add a test that flips `:revenuecat_access_enforcement` to `true` and asserts `GET /api/shopping-list` returns `403 {"error":"subscription_required"}` for an expired Account. Mirror the calendar AC #1 test pattern (PR #70 test suite).
- `meal_planner_api/lib/meal_planner_api_web/channels/planning_channel.ex` — already has `check_handler_entitlement/1` (line 428). The new builder's proof is the controller test; channel capability is unchanged.
- `meal_planner_api/lib/meal_planner_api/generation/server.ex` `broadcast/3` (line 631) — `proposal_confirmed` payload changes shape: `shopping_items_count` reflects the rebuilt-window count, `cart` reflects the net-shortage summary. **Realtime updates for reservation lifecycle (story 21)** are deferred — out of scope.
- `meal_planner_api/lib/meal_planner_api/services/generation_service.ex` `build_cart_lines/2` + `summarize_cart/1` — existing pure functions stay; `summarize_cart/1` is the read-time dedup-by-`(ingredient_id, unit)` for the broadcast payload.
- `meal_planner_api/openspec/changes/planning-shopping-extraction/` — **supersede**: archive this change (it implements the prior pre-spec-#29 contract). #36 replaces it. Do not dual-maintain.

---

## Approaches

### (a) Rebuild inside `Generation.Server.run_confirm_transaction/3` — REPLACE the existing `persist_shopping_cart/2` step

**Description**: Modify the `shopping_cart` Multi step in `run_confirm_transaction/3` (`server.ex:402–404`) to call a new `rebuild_shopping_cart/3` that:
1. Receives `session.range_from` / `session.range_to` (loaded by `mark_committed` earlier in the same Multi).
2. Reads `scheduled_meals WHERE account_id = state.account_id AND date BETWEEN session.range_from AND session.range_to` (NOT just this proposal's slots).
3. Loads `Inventory.available_for(%{account_id: state.account_id})` to get the usable pool.
4. Calls `ShoppingRebuilder.compute_net_shortages/2` (pure) — for each meal's recipe_ingredients, subtracts from the pool greedily, emits `%{scheduled_meal_id, planned_date, ingredient_id, unit, quantity_milli: net_missing}` rows.
5. Wipes existing `ShoppingItem WHERE account_id = ^account_id AND planned_date IN ^range AND status IN [:pending, :in_cart]` (preserves `:checked_out`, `:archived`).
6. Inserts new per-meal rows (NOT NULL `scheduled_meal_id` FK preserved — matches stale Decision 1).
7. Emits the deduped `cart` summary via `summarize_cart/1` for the broadcast/reply payload.

- **Pros**: Atomic with the meal write (the `#36` rebuild invariant is unbreakable); single source of truth (the `scheduled_meals` rows in the same transaction); reuses `Inventory.available_for/2` for usable-inventory; uses the existing session row for the window (no extra query); preserves the NOT-NULL `scheduled_meal_id` FK.
- **Cons**: Touches the same atomic flow as PR #18 / PR #70 / PR #71 — the existing test suite (530 tests at PR #18, additional 740 at PR #70) must be re-run to confirm zero regression. Per-meal grain keeps the same shape; a future spec #29 story 16 acceptance bullet for "normalized exact shortage" is satisfied by the math inside `compute_net_shortages/2`, not by switching to aggregated rows.
- **Effort**: Medium (300–350 production + test lines, single PR works).

### (b) Separate `Shopping.Rebuilder` invoked from a `Phoenix.Channel` listener

**Description**: Same `Multi` step stays as-is; a new `Shopping.Rebuilder.RebuildWorker` subscribes to `proposal_confirmed` on `"planning:#{account_id>"`, fetches `scheduled_meals` for the window, wipes + rebuilds in its own DB transaction, broadcasts `cart_updated`.

- **Pros**: Decouples cart from confirm transaction.
- **Cons**: **NOT atomic with confirm** — a process crash between confirm-commit and rebuilder-ack leaves stale or missing cart; a re-confirm broadcasts `proposal_confirmed` twice; ordering between meal write and cart write is no longer guaranteed. Violates the AC verbatim. Adds a worker (`DynamicSupervisor` + child spec + Registry) the project doesn't currently have. The contract `spec.md` requirement "cart rebuild atomic with confirm" is harder to express as a test when there are two transactions.
- **Effort**: High (400+ lines incl. worker, supervisor, listener tests).

### (c) Sync rebuild inside the same `Ecto.Multi` as `mark_committed/3`

**Description**: Same as (a) — explicitly framed as "add the step inside the existing Multi, do not split into two transactions".

- **Pros**: Identical to (a); atomicity + one source of truth are non-negotiable.
- **Cons**: None vs (a) — the framing is just less ambiguous about what "atomic" means.
- **Effort**: Same as (a).

---

## Recommendation

**Approach (a)/(c)** — the same code, framed two ways. Pick (a) because it's the natural shape (one Multi step replacing another). Reasons it satisfies spec #29's stricter contract vs the stale `planning-shopping-extraction`:

| #29 story | Stale change covers it? | Approach (a) covers it? |
|---|---|---|
| **14** — one shopping list rebuilt from the full active plan | ❌ — only THIS proposal's meals | ✅ — reads all `scheduled_meals` for `(account, range)` |
| **15** — derived from confirmed recipes + meals + inventory, never AI text | ⚠️ — reads `proposal.proposal_json` indirectly via the `scheduled_meals` it just wrote, but the test surface does not assert the invariant | ✅ — rebuild reads `scheduled_meals.recipe_id` only; explicit "no AI text" test asserts the cart payload is invariant to `proposal_json` content |
| **16** — shortages normalized, exact, without package rounding | ❌ — writes raw recipe quantities | ✅ — `compute_net_shortages/2` does integer subtraction; the cart summary is the unit-sum across meals; no `Float.ceil/1` anywhere |
| **17** — insufficient inventory influences optimization but never rejects | N/A in cart code | N/A — `GenerationService.build_cart_lines/2` returns `[]` for missing recipe_id, no exception path |
| **18–21** — reservation lifecycle, purchase, audit, realtime updates | N/A — not implemented | ❌ — explicitly **out of scope** for #36; the proposal must say so |

For the **stale change's open question #1 (grain)** — keep per-meal rows. Per-meal rows + read-time `summarize_cart/1` dedup-by-`(ingredient_id, unit)` gives the user a normalized view without breaking the NOT-NULL `scheduled_meal_id` FK. This matches spec #29 story 16's "normalized" requirement as a **presentation** guarantee, exactly as the stale design.md §3 Decision 1 already documented. The proposal must record this resolution and not relitigate it.

For the **stale change's open question #5 (re-confirm idempotency)** — already resolved by `guard_not_already_confirmed/1` in `do_confirm/3` (`server.ex:427`) PLUS `verify_session_lock/2` (`:lost_lock` / `:committed` / `:expired` rejected before any write, `server.ex:335–375`). Both gates serialize a concurrent double-confirm on the proposal row + the session row; the rebuilder is therefore safe to run idempotently (wipe-then-insert is idempotent when the input set is identical).

---

## Risks

- **PR #18's `persist_shopping_cart/2` is gone** — the 530-test suite from #18 plus the 740-line PR #70 test addition (verified by `git show --stat c56864e`) was designed around raw-recipe-quantity carts. Replacing the math with net-shortage will fail every test that seeded `quantity_milli == recipe_ingredient.quantity_milli` without a corresponding inventory row. The proposal must budget a fixture refresh pass (zero net-new test surface, just updated assertions). Mitigation: write the new math in pure functions first (`ShoppingRebuilder.compute_net_shortages/2`) and back-fill fixtures in the same PR.
- **`Inventory.available_for/2` subtracts reservations from OTHER future meals** — this is what spec #29 wants ("usable inventory"), but it does mean an ingredient reserved for next week's plan is invisible to THIS confirm's cart. That is correct. The proposal must explicitly cite `Inventory.available_for/2` semantics so a reviewer doesn't misread it as "physical stock".
- **Realtime update for reservation events (spec #29 story 21)** is OUT OF SCOPE for #36. The only realtime surface #36 owns is `proposal_confirmed` carrying the rebuilt cart. Reserve `cart_updated`, `cart_reserved`, `cart_purchased` events for the future change that implements stories 18–21.
- **Flag-default posture** for `:revenuecat_access_enforcement` is OFF. AC #1 is satisfied **at code-review level** today; the runtime proof requires flipping the flag (calendar PR2 used the same pattern). Mirror the calendar test (`test/meal_planner_api_web/controllers/calendar_controller_test.exs`) — set `Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)` in a `setup` block, assert `403` + body. If the user wants runtime production enforcement, that's a separate rollout decision.
- **Ecto.UUID.cast accepts ANY 36-char lowercase hex string** — the bug surfaced in PR #70 (`'not-a-valid-uuid'` cast successfully). Tests must use `'not-uuid'` or a similar non-36-char string. Already noted in `planning_channel_test.exs` post-PR #70.
- **Migration risk: zero.** No schema changes for #36. If the user later wants stories 18–21 in scope, a separate migration is required (new `cart_reservations` table OR add `:reserved_in_cart` / `:purchased` to the enum + add `expires_at`).
- **Concurrency**: two members confirming overlapping ranges. The Postgres `EXCLUDE USING gist` on `planning_sessions` (`migration 20260902190000`) prevents two active sessions on the same `(account, range)`. `mark_committed` SELECT-FOR-UPDATE serializes the rest. Cart rebuild is inside the same Multi → no new race.

---

## Spec #29 ↔ #36 cross-check

| #36 AC | Spec #29 story | Spec #29 acceptance | Current code | Current test | Gap |
|---|---|---|---|---|---|
| 1. Expired Account cannot access the shopping list | story 17 (no-reject) + channels/accounts spec | `403 subscription_required` from `:enforce_capability`; `:subscription_required` from `ChannelCapability.authorize/1` | `router.ex:177,196` pipes `/api/shopping-list` through `:enforce_capability`; `planning_channel.ex:46–55` calls `ChannelCapability.authorize/1`; per-handler re-check at `planning_channel.ex:428–434` | None at the flag-on level (PR #18 / #70 only covered `:subscription_required` from `join/3` + `check_handler_entitlement/1`; no shopping-list controller test with flag on) | Add one controller test that flips the flag and asserts the 403 |
| 2. List rebuilds after valid confirmation | story 14 (full-plan rebuild) | After a successful confirm, `shopping_items WHERE account_id = ^a AND planned_date ∈ session.range` reflect the union of all scheduled_meals in that window | `persist_shopping_cart/2` writes only THIS proposal's slots (`server.ex:728`) | PR #18 tasks 3.3 / 3.4 / 4.1 covered per-proposal scope, not full-window scope | Replace `persist_shopping_cart/2` with `rebuild_shopping_cart/3` that reads all scheduled_meals in the window |
| 3. Shortages normalized, exact, without package rounding | story 16 (no rounding) | Cart `quantity_milli` = `max(0, needed − usable_inventory)`, summed across meals per `(ingredient_id, unit)` | `build_cart_lines/2` writes raw recipe quantities; no inventory subtraction in the confirm path | None — `compute_net_shortages/2` is new | New `Services.ShoppingRebuilder.compute_net_shortages/2`; test with full coverage / partial coverage / zero coverage cases |
| 4. List never derived from AI text or unconfirmed proposal | story 15 (provenance) | Cart payload is a pure function of `scheduled_meals.recipe_id` + `inventory_items.quantity_milli` — invariant to `proposal.proposal_json` content | `persist_shopping_cart/2` reads `recipe_ids` from `scheduled_meals.recipe_id` (the proposed rebuilder does the same) — already correct | No explicit "no-AI-text" assertion; depends on transitive coverage | Add an explicit test: seed a proposal whose `proposal_json.slots` contains bogus recipe IDs, confirm a DIFFERENT proposal that reuses the same meals; assert the rebuilt cart is identical to the meals-derived cart and contains NONE of the bogus IDs |

### Stories #36 must NOT regress (in scope for #36 to preserve, but not implement)

- **story 14** — exactly ONE cart for the account per window. Re-confirm must rebuild, not append. Tests on re-confirm: insert a synthetic `pending` `ShoppingItem` for `(account, ingredient, date)` before confirm; assert it is gone after confirm.
- **story 15** — provenance. The new test in AC #4 row above.
- **story 17** — "insufficient inventory influences optimization but never rejects" — `#36` does not change the optimization pipeline. The rebuilder can produce a cart with 99 missing items; confirm still succeeds.

### Stories OUT OF SCOPE for #36 (deferred, must be called out in the proposal)

- **story 18** — reservation lifecycle (`available → reserved_in_cart → purchased`) with 1-hour expiry. Needs a new `cart_reservations` table OR schema additions (`status` enum + `expires_at`).
- **story 19** — actual-quantity purchase confirmation with remainder return to available. New `checkout` flow; needs new `CheckoutSession` state machine + a reverse inventory delta.
- **story 20** — idempotent purchases. Needs an `idempotency_key` column on the checkout payload.
- **story 21** — auditable inventory movements + realtime updates for cart lifecycle. `inventory_mutation_events` already has `trigger_type = :purchase`, so the audit row exists; the realtime fan-out (`cart_reserved`, `cart_purchased`) does not.

---

## Suggested PR slicing

The project pattern for stacked-to-main per issue is 2–3 PRs (PRs #53–#57 for #30, #61–#65 for #33, #66–#68 for #34, #69–#71 for #35). Two PRs fit #36's scope comfortably; a third is optional only if the `ShoppingCheckout.sync_from_planning/4` refactor lands.

### PR1 — Pure net-shortage math + window wipe (≤ 200 lines)

**Scope**:
- New `Services.ShoppingRebuilder.compute_net_shortages/2` — pure, takes `[ScheduledMeal.t()] + %{available_pool_by_key}`, returns `[%{scheduled_meal_id, planned_date, ingredient_id, unit, quantity_milli: net_missing}]`. No DB.
- New `Data.ShoppingRepo.delete_pending_for_window/2` — `Repo.delete_all` scoped to `(account_id, planned_date BETWEEN, status IN [:pending, :in_cart])`. Pure data layer.
- Reuse `Services.GenerationService.summarize_cart/1` (already pure).

**Tests (RED-first)**:
- `compute_net_shortages/2` — full coverage / partial coverage / zero coverage / mixed units / same-ingredient-two-meals dedup / empty meals.
- `delete_pending_for_window/2` — wipes pending + in_cart, preserves checked_out + archived, scoped to account + range, multi-account isolation.

**Why this PR is safe to land alone**: zero behavior change. Nothing calls these functions yet. Mirrors the stale PR1 (`planning-shopping-extraction` PR1) pattern that #18 used.

### PR2 — Rebuild inside `run_confirm_transaction` + capability-gate proof + provenance test (≤ 350 lines)

**Scope**:
- Replace `Generation.Server.persist_shopping_cart/2` (`server.ex:728`) with `rebuild_shopping_cart/3`:
  1. Read `session.range_from/range_to` from the `mark_committed` step output.
  2. Read `scheduled_meals` for `(account, range)` via `Persistence.Planning.list_scheduled_meals/3` + `Repo.preload(recipe: :recipe_ingredients)`.
  3. Load `Inventory.available_for(%{account_id: state.account_id})` and build the available pool.
  4. Call `ShoppingRebuilder.compute_net_shortages/2`.
  5. Call `ShoppingRepo.delete_pending_for_window/2`.
  6. Insert per-meal `ShoppingItem` rows (preserves NOT-NULL `scheduled_meal_id` FK).
  7. Return `summarize_cart/1` for the broadcast/reply payload.
- Extend `proposal_confirmed` payload and `{:ok, summary}` reply with the net-shortage `cart` and the new `shopping_items_count`.
- Add `test/meal_planner_api_web/controllers/shopping_controller_test.exs` test: flip `:revenuecat_access_enforcement` to `true`, seed an expired Account, hit `GET /api/shopping-list`, assert `403 {"error":"subscription_required"}`.
- Add the explicit "no AI text" provenance test in `test/meal_planner_api/generation/server_test.exs`: seed two proposals with the same meals but different `proposal_json` content, confirm one, mutate the OTHER's `proposal_json` to contain bogus recipe IDs, assert the rebuilt cart is identical and contains none of the bogus IDs.
- Refresh fixtures in the existing PR #18 + PR #70 tests to reflect net-shortage math (recipes with seeded inventory → no shopping row; recipes without inventory → row with recipe quantity).

**Why the 400-line cap holds**: production change is ~100 lines (replace one function, add two helpers); tests are ~250 lines (one server-layer test, one channel-layer test, one controller-layer test, ~10 fixture refreshes). Mirrors PR #70's 207-prod + 740-test ratio for a comparable scope.

### PR3 (OPTIONAL) — Refactor `ShoppingCheckout.sync_from_planning/4` to share the math (≤ 100 lines)

**Scope**: extract the per-meal loop from `ShoppingCheckout.sync_from_planning/4` (`shopping_checkout.ex:263–292`) into a pure function that delegates to `ShoppingRebuilder.compute_net_shortages/2`. The HTTP `GET /api/shopping-list` fallback path and the channel `proposal_confirmed` path then share ONE source of truth for net-shortage math.

**Why optional**: `sync_from_planning/4` already short-circuits when there are open items, so its current code path is dead in production after PR2 (the rebuild on confirm populates the pending rows). The refactor is hygienic, not load-bearing. Defer if the user wants to ship #36 in 2 PRs.

**Budget flag**: PR2 is the riskiest slice at ~350 lines; if any of the test fixtures balloon unexpectedly, split the controller capability-gate test into PR3 and keep PR2 ≤ 300 lines.

---

## Ready for Proposal

**Yes** — with three conditions the orchestrator should relay to the user before launching `sdd-propose`:

1. **AC scope is stories 14–17, not 14–21.** Stories 18–21 (reservation lifecycle, purchase, expiry, audit, realtime cart events) are explicitly **out of scope for #36**. The proposal must say so in §"Intent" and the spec must encode the deferred stories as "MODIFIED Requirements → future change", not "REMOVED". This avoids the false impression that #36 closes the whole spec #29.
2. **Cart rebuild lives inside `run_confirm_transaction/3`**, not in a separate worker. The seam is the existing `Ecto.Multi`. The stale `planning-shopping-extraction/change` folder will be archived (replaced) — confirm with the user that archiving the stale change (which still has a `proposal.md` / `design.md` / `specs/` / `tasks.md` that don't fully match spec #29) is OK.
3. **Capability-gate runtime proof mirrors the calendar PR2 pattern.** Setting `Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)` in a `setup` block is acceptable; whether to FLIP the default in production is a separate rollout decision the user must own.

Once those three are answered, the orchestrator can launch `sdd-propose` against `meal_planner_api/openspec/changes/shopping-derived-from-confirmed-plan/`.
