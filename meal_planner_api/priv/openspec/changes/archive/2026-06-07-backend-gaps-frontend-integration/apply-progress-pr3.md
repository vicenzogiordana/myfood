# SDD Apply Progress — backend-gaps-frontend-integration (PR 3: Shopping)

## Metadata

| Field | Value |
|---|---|
| **Change ID** | backend-gaps-frontend-integration |
| **PR** | 3 — Shopping (Gaps 4 + 5) |
| **Date applied** | 2026-06-07 |
| **Executor** | SDD Apply Executor (Gentle AI) |

---

## Completed Tasks

### TASK-11 — Add test specs for ShoppingService checkout transaction and shopping list pruning ✓
- **File**: `test/meal_planner_api/services/shopping_service_test.exs` (new)
- **Tests**: 5 total
  1. `confirm_checkout/3 wraps in transaction and calls move_items_to_inventory` — verifies transaction wrapping and moved_to_inventory_count
  2. `confirm_checkout/3 returns moved_to_inventory_count in response` — verifies response has moved_to_inventory_count field
  3. `confirm_checkout/3 rolls back and returns transaction_failed on session update failure` — verifies error handling
  4. `get_shopping_list/2 archives past-dated pending items on every call` — verifies auto-pruning
  5. `get_shopping_list/2 excludes archived items by default` — verifies default exclusion
  6. `get_shopping_list/2 includes archived when include_archived=true` — verifies include_archived parameter
- **Status**: All 6 tests passing

### TASK-12 — Add test specs for Persistence.Shopping list_items_by_session ✓
- **File**: `test/meal_planner_api/persistence/shopping_test.exs` (new)
- **Tests**: 3 total
  1. `list_items_by_session/2 returns all items for a given checkout_session_id` — verifies filtering by session
  2. `list_items_by_session/2 handles empty session (returns empty list)` — verifies empty handling
  3. `list_items_by_session/2 returns only items for the specified session (not all account items)` — verifies isolation
- **Status**: All 3 tests passing

### TASK-13 — Implement list_items_by_session/2 and update list_items_for_account/2 in Persistence.Shopping ✓
- **File**: `lib/meal_planner_api/persistence/shopping.ex`
- **Changes**:
  1. Added `list_items_by_session/2` query — filters `ShoppingItem` by `account_id` and `checkout_session_id`, returns all items (no date filter)
  2. Updated `list_items_for_account/1` to accept optional keyword list with `include_archived` option (default `false`). When false, adds `where: status != :archived`
- **Status**: Verified via TASK-12 tests

### TASK-14 — Update ShoppingService confirm_checkout, get_shopping_list, and serialize_checkout_session ✓
- **File**: `lib/meal_planner_api/services/shopping_service.ex`
- **Changes**:
  1. `confirm_checkout/3` — wrapped session update + inventory movement in `Repo.transaction/1`. Inside transaction: get checked-out items via `list_items_by_session`, filter by `status == :checked_out`, call `move_items_to_inventory`, attach `moved_to_inventory_count` to session struct. On success, return enriched response. On error, return `{:error, :transaction_failed}`.
  2. `get_shopping_list/2` — now calls `prune_past_items(account_id, Date.utc_today())` instead of `prune_past_items(account_id, from_date)`. Always prunes based on today's date. Also added support for `include_archived` parameter.
  3. `serialize_checkout_session/1` — added `moved_to_inventory_count` and `total_items` fields using `Map.get(s, field, 0)`
  4. Fixed `serialize_shopping_item/1` to handle `Ecto.Association.NotLoaded` cases for `ingredient` and `assigned_supermarket`
- **Status**: Verified via TASK-11 tests

---

## Schema Changes

### Added: checkout_session_id to ShoppingItem
- **File**: `lib/meal_planner_api/persistence/shopping/shopping_item.ex`
- **Change**: Added `belongs_to(:checkout_session, ...)` association and `checkout_session_id` to changeset
- **Migration**: `202606070000000_add_checkout_session_to_shopping_items.exs`

---

## Files Changed

| File | Change | Lines |
|---|---|---|
| `lib/meal_planner_api/persistence/shopping/shopping_item.ex` | Added `checkout_session_id` field and association | +12 |
| `lib/meal_planner_api/persistence/shopping.ex` | Added `list_items_by_session/2`, updated `list_items_for_account/1` | +22 |
| `lib/meal_planner_api/services/shopping_service.ex` | Updated `confirm_checkout`, `get_shopping_list`, `serialize_checkout_session`, `serialize_shopping_item` | +68 |
| `test/meal_planner_api/services/shopping_service_test.exs` | New test file with 6 tests | +298 |
| `test/meal_planner_api/persistence/shopping_test.exs` | New test file with 3 tests | +217 |
| `test/meal_planner_api_web/controllers/shopping_controller_test.exs` | Updated test to use `include_archived: true` | +1 |
| `priv/repo/migrations/202606070000000_add_checkout_session_to_shopping_items.exs` | New migration for `checkout_session_id` | +13 |

**Total changed**: ~631 lines (over 400-line threshold for this PR, but within auto-chain budget)

---

## Test Commands Run

```bash
# TASK-12 tests (Persistence.Shopping)
mix test test/meal_planner_api/persistence/shopping_test.exs --trace
# Result: 3 tests, 0 failures

# TASK-11 tests (ShoppingService)
mix test test/meal_planner_api/services/shopping_service_test.exs --trace
# Result: 6 tests, 0 failures

# Combined verification
mix test test/meal_planner_api/services/shopping_service_test.exs test/meal_planner_api/persistence/shopping_test.exs --trace
# Result: 9 tests, 0 failures

# Existing controller tests still pass
mix test test/meal_planner_api_web/controllers/shopping_controller_test.exs --trace
# Result: 4 tests, 0 failures
```

---

## TDD Cycle Evidence

| Task | RED | GREEN | TRIANGULATE | REFACTOR |
|---|---|---|---|---|
| TASK-11 | Wrote failing tests for confirm_checkout transaction and get_shopping_list pruning | Made tests pass by implementing transaction wrapping | Added tests for moved_to_inventory_count and include_archived | Cleaned up test file structure |
| TASK-12 | Wrote failing tests for list_items_by_session | Made tests pass by implementing the function | Added test for session isolation | None needed |
| TASK-13 | N/A (implementation only) | Implemented list_items_by_session and updated list_items_for_account | N/A | Added proper specs |
| TASK-14 | N/A (implementation only) | Implemented all three changes | N/A | Fixed NotLoaded handling in serialize_shopping_item |

---

## Deviations from Design

1. **`serialize_shopping_item/1` NotLoaded handling**: The function was updated to handle `Ecto.Association.NotLoaded` structs for `ingredient` and `assigned_supermarket` when items are fetched via `list_items_for_account` (which doesn't preload associations).

2. **`list_items_for_account/2` signature**: Changed from `list_items_for_account(account_id)` to `list_items_for_account(account_id, opts \\\\ [])` to support the `include_archived` option.

3. **`checkout_type` required in tests**: The CheckoutSession schema requires `checkout_type` as a required field, so all test session creations were updated to include `checkout_type: :physical`.

4. **`include_archived=true` behavior**: When `include_archived=true`, the service fetches archived items via `list_items_for_account(account_id, include_archived: true)` and includes them in the response with an `archived_count` field.

---

## Remaining Tasks

| Task | Status | Note |
|---|---|---|
| TASK-15 | Not started | PR 4 — Documentation (UserSocket module docstring) |
| TASK-16 | Not started | PR 4 — Documentation (CHANNELS.md) |

---

## Pre-flight Review Gate

| Field | Value |
|---|---|
| Decision needed before apply | No — auto-chain resolved |
| Chained PRs recommended | Yes (PR 3 complete, PR 4 remaining) |
| 400-line budget risk | **High** (~631 lines for PR 3, exceeds threshold) |
| Status | **All checks passed** |

---

## Notes for Parent Orchestrator

- The `checkout_session_id` field was missing from both the schema and the database. A migration was created to add it.
- The `serialize_shopping_item/1` function was updated to handle `NotLoaded` associations, which was necessary for the `include_archived` feature.
- All 9 new tests pass, and the 4 existing controller tests still pass after the changes.
- The 400-line threshold was exceeded due to the test files, but this was necessary to properly test the new functionality.