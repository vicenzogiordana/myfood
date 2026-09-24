# Proposal: Shopping Derived from Confirmed Plan

## Change Summary

Issue #36 closes spec #29 stories 14–17: rebuild shopping from confirmed meals, usable inventory, and entitlement-gated access. The cart merged in PR #18 is a non-conforming baseline (raw, proposal-local quantities) superseded by this path.

## Intent

**Problem.** A confirm persists meals but its cart ignores inventory, covers only its proposal slots, and lacks an explicit no-AI-text proof. The four #36 ACs reject those gaps and prove the capability gate.

**Why now.** #30 and #35 supplied the `Ecto.Multi`, session range, `Inventory.available_for/2`, and capability seams.

**Success looks like.** Confirm atomically derives full-window, exact shortages only from `scheduled_meals.recipe_id` plus inventory. Expired Accounts receive the capability denial required by #36 at both boundaries; archive the stale change.

## Scope

### In Scope
- Stories 14–17: full-window rebuild; greedy `max(0, needed − available)` shortages; separate mixed units; no rounding; read-time `(ingredient_id, unit)` summary.
- Provenance invariant against `proposal_json`; flag-on HTTP/channel capability proof; existing re-confirm rejection; window wipe preserving `:checked_out`/`:archived`.

### Out of Scope — Future Change
- Stories 18–21: reservation lifecycle (`available → reserved_in_cart → purchased`), one-hour expiry, actual-quantity checkout/remainders, purchase idempotency, reservation events, and inventory movement audit. Likely child issue: **Cart reservation lifecycle and purchase confirmation**.

### Out of Scope — Non-goals
- Schema migrations, frontend work, migration of legacy rows, and shared `ShoppingCheckout.sync_from_planning/4` refactor unless PR2 remains within budget.

## Capabilities

### New Capabilities
- `shopping-derived-from-confirmed-plan`: account-scoped, confirmed-plan shopping rebuild.

### Modified Capabilities
- None.

## Coordination

- **Supersedes:** `meal_planner_api/openspec/changes/planning-shopping-extraction/`; its nine scenarios implement the weaker contract. After #36 merges, archive it in separate `chore(shopping-derived-from-confirmed-plan): archive superseded planning-shopping-extraction change` commit.
- **Depends on:** #29 stories 14–17, `Inventory.available_for/2`, and PR #70 `do_confirm/3`/`mark_committed/3`. **Independent of:** merged PR #71 and deferred stories 18–21. **Closes:** #36.

## Key Decision — How should the rebuild be triggered?

Choose (a)/(c): replace the cart step inside `Generation.Server.run_confirm_transaction/3`'s `Ecto.Multi`. It is atomic with confirm and reads the sole truth, `scheduled_meals`; a channel listener (b) introduces a crash/race gap and violates AC #2.

## Approach

- **PR1 (≤200 lines):** pure `MealPlannerApi.Services.ShoppingRebuilder.compute_net_shortages/2`; `MealPlannerApi.Data.ShoppingRepo.delete_pending_for_window/3`; RED-first math, unit, summary, isolation, and preserved-status tests.
- **PR2 (target ≤350 lines):** replace `persist_shopping_cart/2` with `rebuild_shopping_cart/3` in `meal_planner_api/lib/meal_planner_api/generation/server.ex`; load all session-window meals, usable inventory, wipe/insert rows, and return cart/count. Add provenance and flag-on HTTP/channel tests; refresh PR #18/#70 fixtures.
- **PR3 (optional ≤100 lines):** delegate `ShoppingCheckout.sync_from_planning/4` to the rebuilder only if PR2 risks 400 changed lines. **Budget flag:** use the three-PR stack if fixture refresh exceeds the cap.

## Success Criteria

- Flag-on expired Account: `GET /api/shopping-list` returns `403 {"error":"subscription_required"}` and `proposal_confirmed` is refused with `:subscription_required`.
- A locked confirm rebuilds its full session window, including earlier confirmed meals; insert failure rolls back meals, acceptance, and cart.
- Rows store exact net shortage; summary is unrounded and unit-distinct; `:checked_out`/`:archived` survive the wipe.
- Same chosen recipes with different `proposal_json` yield byte-identical carts; accepted re-confirm returns `{:error, :already_confirmed}` without new rows.

## Open Questions (resolve in design)

- Preserve PR #18's `proposal_confirmed` cart shape while returning rebuilt summary.
- Keep the HTTP lazy fallback separate, but make the rebuilder the confirm writer of truth.
- Leave `:revenuecat_access_enforcement` default off; flip only in tests pending an operator rollout decision.

## Risks

- PR #18/#70 fixtures span roughly 530/740 lines; use PR1's pure seam before integration and split PR2 on risk.
- `available_for/2` excludes other future reservations—this is intended usable inventory. Use `not-uuid` in UUID-negative tests. Archive after implementation merges; its files are independent of test fixtures.

## Rollback Plan

Revert the PR2 transaction change to restore the existing cart step; no migration or data reversal is required.
