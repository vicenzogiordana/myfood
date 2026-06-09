# SDD Apply Progress — python-integration-fix

**Change ID:** `python-integration-fix`
**Date:** 2026-06-09
**Status:** COMPLETED

---

## Summary

Fixed the Elixir-Python integration by creating a payload adapter that translates between GenerationServer's slot-based format and OptimizerServer's Python-compatible format.

**Root Cause:** GenerationServer called `PythonClient.optimize_menu/3` which sends HTTP POST to a non-existent endpoint with incompatible payload format. `optimizador.py` expects Port/stdio JSON protocol with a completely different structure.

**Solution:** Created `PayloadAdapter` module + replaced `PythonClient` call in `GenerationServer` with `OptimizerServer` call via the adapter.

---

## Completed Tasks

### ✅ TASK-1: Create PayloadAdapter module
**File:** `lib/meal_planner_api/optimization/payload_adapter.ex`

Implemented:
- `build_optimizer_payload/3` - Translates `{slots, recipe_prices, recipe_macros}` → `{days, slots, constraints, candidates_by_slot}`
- `translate_response/2` - Translates optimizer response to GenerationServer format with DB data enrichment

Key helpers:
- `compute_weekly_budget/1` - Sums per-slot budgets
- `compute_macro_bounds/1` - Computes weekly macro bounds with ±30% buffer
- `build_candidates_by_slot/3` - Builds candidates with price and macros
- `macro_estimate/2` - Estimates carbs/fat from available data

**Lines changed:** ~180 (new file)

---

### ✅ TASK-2: Add RecipeRepo.list_by_ids_with_prices/1
**File:** `lib/meal_planner_api/data/recipe_repo.ex`

Added:
```elixir
@spec list_by_ids_with_prices([pos_integer()]) :: [Recipe.t()]
def list_by_ids_with_prices(recipe_ids) when is_list(recipe_ids) do
  from(r in Recipe,
    where: r.id in ^recipe_ids,
    preload: [:recipe_price]
  )
  |> Repo.all()
end
```

**Lines changed:** +12

---

### ✅ TASK-3: Update GenerationServer
**File:** `lib/meal_planner_api/generation/server.ex`

Changes:
1. Added imports for `OptimizerServer` and `PayloadAdapter`
2. Removed unused `PythonClient` import
3. Updated `run_pipeline/1` to:
   - Use `PayloadAdapter.build_optimizer_payload/3` to translate slot format
   - Call `OptimizerServer.select_weekly_menu/1` (Port/stdio, working)
   - Use `PayloadAdapter.translate_response/2` to translate response
4. Added helper functions:
   - `load_recipe_data_for_response/1` - Loads recipe data with prices preloaded
   - `convert_prices_to_string_keys/1` - Converts integer keys to strings
   - `convert_macros_to_string_keys/1` - Converts integer keys to strings

**Lines changed:** ~50

---

### ✅ TASK-4: Add PayloadAdapter unit tests
**File:** `test/meal_planner_api/optimization/payload_adapter_test.exs` (new)

Test cases:
- `build_optimizer_payload/3` with single slot → correct output structure
- `build_optimizer_payload/3` with multiple dates → days deduplicated
- `build_optimizer_payload/3` with multiple slot types → slots list correct
- `build_optimizer_payload/3` computes weekly_budget_cents correctly
- `build_optimizer_payload/3` computes macro_bounds with buffer
- `build_optimizer_payload/3` builds candidates_by_slot with full recipe data
- `build_optimizer_payload/3` handles missing recipe data with defaults
- `translate_response/2` with valid result → enriches with recipe_data
- `translate_response/2` with error → propagates error

**Lines changed:** ~220 (new file)

---

### ✅ TASK-5: Update GenerationServer tests
**File:** `test/meal_planner_api/generation/server_test.exs`

No changes required - existing tests are interface-level tests that don't mock PythonClient.

---

### ✅ TASK-6: Full test suite regression

**Command:** `mix test`
**Result:** 272 tests, 0 failures

---

## Files Changed

| File | Change | Lines |
|------|--------|-------|
| `lib/meal_planner_api/optimization/payload_adapter.ex` | New module | +180 |
| `lib/meal_planner_api/data/recipe_repo.ex` | Added list_by_ids_with_prices/1 | +12 |
| `lib/meal_planner_api/generation/server.ex` | Replaced PythonClient with OptimizerServer via PayloadAdapter | ~50 |
| `test/meal_planner_api/optimization/payload_adapter_test.exs` | New test file | +220 |

**Total: ~462 lines** (over 400-line threshold, but single PR is acceptable)

---

## Architecture

```
                    GenerationServer.run_pipeline()
                              │
                              ▼
                    ┌─────────────────────┐
                    │  build_slots_input  │
                    │  PriceService       │
                    │  fetch_recipe_prices │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ PayloadAdapter     │
                    │ .build_optimizer_   │
                    │ payload/3           │
                    │ (TRANSLATION)       │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ OptimizerServer     │
                    │ .select_weekly_menu │
                    │ (Port/stdio, works) │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ PayloadAdapter     │
                    │ .translate_response│
                    │ /2                  │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ load_recipe_data   │
                    │ (DB lookup)         │
                    └─────────┬───────────┘
                              │
                              ▼
                    GenerationServer.proposal_json
```

---

## Deviations from Design

None - followed DESIGN.md exactly.

---

## Risks & Mitigations

| Risk | Status |
|------|--------|
| GenerationServer state machine broken | ✅ Verified - state machine unchanged |
| Macro bounds miscalculated | ✅ Documented conversion (per-slot → weekly) |
| Recipe data lookup fails | ✅ Uses defaults (0 for missing, "Unknown Recipe" for name) |
| OptimizerServer circuit breaker activates | ✅ Falls back to `OptimizerFallback` (existing behavior) |

---

## TDD Evidence

**RED phase:** Wrote failing tests first (10 test cases)
**GREEN phase:** Implemented PayloadAdapter, all tests pass
**REFACTOR phase:** No refactoring needed

---

## Pre-existing Warnings

The following warnings existed before this change and are unrelated:
- `parse_bool/1 is unused` in `shopping_controller.ex:129`
- Various unused variable warnings in test files

---

## Next Steps

1. **Review:** Parent orchestrator should review changes before commit
2. **Commit:** Do NOT commit - return for parent review
3. **PythonClient deprecation:** Consider adding `@deprecated` notice to PythonClient module (optional)

---

## Verification Commands

```bash
# Compile
mix compile

# PayloadAdapter tests
mix test test/meal_planner_api/optimization/payload_adapter_test.exs

# GenerationServer tests
mix test test/meal_planner_api/generation/server_test.exs

# Full suite
mix test
```

---

**Status:** ✅ READY FOR REVIEW - Do not commit yet