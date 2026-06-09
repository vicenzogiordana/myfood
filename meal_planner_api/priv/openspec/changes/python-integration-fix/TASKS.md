# SDD TASKS — python-integration-fix

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~300 total |
| 400-line budget risk | **Low** |
| Chained PRs recommended | No — single PR |
| Delivery strategy | auto-apply |

**Decision needed before apply: No (single PR, under threshold)**

---

## Task List

### TASK-1: Create PayloadAdapter module

**File:** `lib/meal_planner_api/optimization/payload_adapter.ex`
**Estimated lines:** ~120
**Dependencies:** None

**Steps:**
1. Create module with `build_optimizer_payload/3` function
2. Implement `compute_weekly_budget/1` helper
3. Implement `compute_macro_bounds/1` helper
4. Implement `build_candidates_by_slot/3` helper
5. Implement `translate_response/2` function

**Verification:** `mix compile` succeeds

---

### TASK-2: Add RecipeRepo.list_by_ids_with_prices/1

**File:** `lib/meal_planner_api/data/recipe_repo.ex`
**Estimated lines:** ~10
**Dependencies:** TASK-1

**Steps:**
1. Add `list_by_ids_with_prices/1` function
2. Use `from(r in Recipe, where: r.id in ^recipe_ids, preload: [:recipe_price])`
3. Add `@spec` type annotation

**Verification:** `mix compile` succeeds

---

### TASK-3: Update GenerationServer to use PayloadAdapter

**File:** `lib/meal_planner_api/generation/server.ex`
**Estimated lines:** ~40
**Dependencies:** TASK-1, TASK-2

**Steps:**
1. Add imports for `PayloadAdapter` and `OptimizerServer`
2. Remove import for `PythonClient` (or keep but don't use)
3. Update `run_pipeline/1` to:
   - Call `PayloadAdapter.build_optimizer_payload/3`
   - Call `load_recipe_data_for_response/1`
   - Call `OptimizerServer.select_weekly_menu/1`
   - Call `PayloadAdapter.translate_response/2`
4. Add `load_recipe_data_for_response/1` helper function

**Verification:** `mix compile` succeeds

---

### TASK-4: Add PayloadAdapter unit tests

**File:** `test/meal_planner_api/optimization/payload_adapter_test.exs` (new)
**Estimated lines:** ~120
**Dependencies:** TASK-1

**Steps:**
1. Create test module with `use ExUnit.Case`
2. Test `build_optimizer_payload/3`:
   - Single slot, single recipe → correct output
   - Multiple dates → days deduplicated
   - Multiple slot types → slots list correct
   - Weekly budget computed correctly
   - Macro bounds computed correctly
   - candidates_by_slot built with full recipe data
3. Test `translate_response/2`:
   - Valid result → enriches with recipe_data
   - Error result → propagates error

**Verification:** `mix test test/meal_planner_api/optimization/payload_adapter_test.exs`

---

### TASK-5: Update GenerationServer tests

**File:** `test/meal_planner_api/generation/server_test.exs`
**Estimated lines:** ~20
**Dependencies:** TASK-3

**Steps:**
1. Update mock expectations: `OptimizerServer` instead of `PythonClient`
2. Add test for `load_recipe_data_for_response/1`

**Verification:** `mix test test/meal_planner_api/generation/server_test.exs`

---

### TASK-6: Full test suite regression

**Command:** `mix test`
**Expected:** All 262+ tests pass, 0 failures

---

## Implementation Order

```
TASK-1 (PayloadAdapter module)
    ↓
TASK-2 (RecipeRepo function)
    ↓
TASK-3 (GenerationServer update)
    ↓
TASK-4 (PayloadAdapter tests)
    ↓
TASK-5 (GenerationServer tests update)
    ↓
TASK-6 (Full suite regression)
```

---

## Verification Commands

```bash
# TASK-1, TASK-2, TASK-3
mix compile

# TASK-4
mix test test/meal_planner_api/optimization/payload_adapter_test.exs

# TASK-5
mix test test/meal_planner_api/generation/server_test.exs

# TASK-6
mix test
```

---

## Acceptance Criteria

- [ ] `PayloadAdapter` module compiles and exports `build_optimizer_payload/3`, `translate_response/2`
- [ ] `RecipeRepo.list_by_ids_with_prices/1` compiles
- [ ] `GenerationServer.run_pipeline/1` calls `OptimizerServer` via `PayloadAdapter`
- [ ] All `PayloadAdapter` tests pass (8+ tests)
- [ ] All `GenerationServer` tests pass
- [ ] Full test suite passes (262+ tests, 0 failures)