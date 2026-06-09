# SDD SPEC — python-integration-fix

## Overview

Fix the Elixir-Python integration by creating a payload adapter that translates between `GenerationServer`'s slot-based format and `OptimizerServer`'s Python-compatible format.

## Problem

`GenerationServer` calls `PythonClient.optimize_menu/3` which sends HTTP POST to a non-existent endpoint with incompatible payload format. `optimizador.py` expects a Port/stdio JSON protocol with a completely different structure.

## Solution: OptimizerPayloadAdapter

Create `lib/meal_planner_api/optimization/payload_adapter.ex` that:
1. Translates `{slots, recipe_prices, recipe_macros}` → `{days, slots, constraints, candidates_by_slot}`
2. Calls `OptimizerServer.select_weekly_menu/1` (Port/stdio, working)
3. Translates response back to `GenerationServer` expected format

---

## SPEC 1: OptimizerPayloadAdapter module

### Module: `MealPlannerApi.Optimization.PayloadAdapter`

### Function: `build_optimizer_payload/3`

**Signature:**
```elixir
@spec build_optimizer_payload(
  slots :: [%{date: String.t(), slot: atom(), available_recipe_ids: [String.t()], constraints: map()}],
  recipe_prices :: %{String.t() => float()},
  recipe_macros :: %{String.t() => %{protein_g: integer(), calories: integer(), carbs_g: integer()}}
) :: map()
```

**Input format:**
```elixir
%{
  slots: [
    %{date: "2026-06-03", slot: :lunch, available_recipe_ids: ["1", "2", "3"], constraints: %{...}},
    ...
  ],
  recipe_prices: %{"1" => 12.50, "2" => 9.50},
  recipe_macros: %{"1" => %{protein_g: 25, calories: 450, carbs_g: 30}}
}
```

**Output format (Python-compatible):**
```elixir
%{
  days: ["2026-06-03", "2026-06-04", ...],
  slots: ["breakfast", "lunch", "dinner"],
  constraints: %{
    weekly_budget_cents: 45000,
    macro_bounds: %{
      protein_g: %{min: 100.0, max: 150.0},
      carbs_g: %{min: 225.0, max: 325.0},
      fat_g: %{min: 44.0, max: 78.0}
    }
  },
  candidates_by_slot: %{
    "lunch" => [
      %{recipe_id: "1", estimated_cost_cents: 1250, protein_g_per_serving: 25.0, carbs_g_per_serving: 30.0, fat_g_per_serving: 10.0},
      ...
    ]
  }
}
```

**Translation rules:**
1. Extract all unique dates from slots → `days`
2. Extract all unique slot types → `slots`
3. Compute `weekly_budget_cents`: sum of per-slot `budget_cents` from first slot's constraints (or use first constraint value)
4. Compute `macro_bounds`:
   - `protein_g.min` = sum of all slot `protein_g` values × 0.7 (buffer for flexibility)
   - `protein_g.max` = sum of all slot `protein_g` values × 1.3
   - Same for carbs_g, fat_g (default: carbs = protein × 3, fat = protein × 0.4)
5. Build `candidates_by_slot`:
   - For each slot type, collect all recipes from all slots with that slot type
   - Deduplicate by recipe_id
   - For each recipe, look up price from `recipe_prices` (multiply by 100 for cents) and macros from `recipe_macros`
   - Convert macros: protein_g stays, calories → carbs_g (calories/4), fat_g = protein_g × 0.4 (default)

### Function: `translate_response/2`

**Signature:**
```elixir
@spec translate_response(
  optimizer_result :: {:ok, %{meals: [%{day: String.t(), slot: String.t(), recipe_id: String.t()}]}} | {:error, term()},
  recipe_data :: %{String.t() => %{name: String.t(), price_cents: integer(), protein_g: integer(), calories: integer(), carbs_g: integer()}}
) :: {:ok, [%{date: String.t(), slot: String.t(), recipe_id: String.t(), recipe_name: String.t(), price_cents: integer(), macros: map()}]} | {:error, term()}
```

**Input from OptimizerServer:**
```elixir
{:ok, %{meals: [%{day: "2026-06-03", slot: "lunch", recipe_id: "1"}, ...]}}
```

**Output for GenerationServer:**
```elixir
{:ok, [
  %{date: "2026-06-03", slot: "lunch", recipe_id: "1", recipe_name: "Pollo al horno", price_cents: 1250, macros: %{protein_g: 25, calories: 450, carbs_g: 30}},
  ...
]}
```

**Translation rules:**
1. For each meal, look up `recipe_data[recipe_id]`
2. Extract `name` → `recipe_name`
3. Extract `price_cents` (already in cents)
4. Extract macros → `macros` map

---

## SPEC 2: Update GenerationServer

### File: `lib/meal_planner_api/generation/server.ex`

### Change: Replace `PythonClient.optimize_menu/3` call

**Current code (line ~228):**
```elixir
case PythonClient.optimize_menu(slots_input, recipe_prices, recipe_macros) do
  {:ok, optimized_slots} ->
    proposal_json = GenerationService.build_proposal_json(optimized_slots)
    ...
```

**New code:**
```elixir
# Build optimizer payload (translate format)
optimizer_payload = PayloadAdapter.build_optimizer_payload(slots_input, recipe_prices, recipe_macros)

# Get recipe data for response translation
recipe_data = load_recipe_data_for_response(all_recipe_ids)

# Call OptimizerServer (Port/stdio, working integration)
case OptimizerServer.select_weekly_menu(optimizer_payload) do
  {:ok, optimizer_result} ->
    # Translate response and enrich with DB data
    optimized_slots = PayloadAdapter.translate_response({:ok, optimizer_result}, recipe_data)
    proposal_json = GenerationService.build_proposal_json(optimized_slots)
    ...
  {:error, reason} ->
    handle_optimization_error(run_id, reason, state)
end
```

### New function: `load_recipe_data_for_response/1`

**Purpose:** Load recipe name, price, and macros from DB for response enrichment.

```elixir
@spec load_recipe_data_for_response([pos_integer()]) :: %{String.t() => map()}
defp load_recipe_data_for_response(recipe_ids) do
  recipe_ids
  |> RecipeRepo.list_by_ids_with_prices()
  |> Enum.into(%{}, fn recipe ->
    {to_string(recipe.id), %{
      name: recipe.name,
      price_cents: recipe.recipe_price && recipe.recipe_price.price_per_serving_cents || 0,
      protein_g: recipe.protein_g_per_serving || 0,
      calories: recipe.calories_per_serving || 0,
      carbs_g: recipe.carbs_g_per_serving || 0
    }}
  end)
end
```

---

## SPEC 3: Add RecipeRepo function

### File: `lib/meal_planner_api/data/recipe_repo.ex`

### New function: `list_by_ids_with_prices/1`

**Purpose:** Load recipes with prices preloaded (for response enrichment).

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

---

## SPEC 4: Update tests

### Test file: `test/meal_planner_api/optimization/payload_adapter_test.exs` (new)

**Test cases:**
1. `build_optimizer_payload/3` with single slot → correct days/slots/candidates
2. `build_optimizer_payload/3` with multiple dates → deduplicates days
3. `build_optimizer_payload/3` with multiple slot types → correct slots list
4. `build_optimizer_payload/3` computes weekly_budget_cents from per-slot budget
5. `build_optimizer_payload/3` computes macro_bounds from constraints
6. `build_optimizer_payload/3` builds candidates_by_slot with full recipe data
7. `translate_response/2` with valid result → enriches with recipe_data
8. `translate_response/2` with error → propagates error

### Test file: `test/meal_planner_api/generation/server_test.exs` (update)

**Update existing tests:**
- Update `run_pipeline` mock expectations to use `OptimizerServer` instead of `PythonClient`
- Add test for `load_recipe_data_for_response/1`

---

## SPEC 5: Deprecate PythonClient (production)

### File: `lib/meal_planner_api/integrations/python_client.ex`

**Add deprecation notice:**
```elixir
@deprecated "Use OptimizerServer via PayloadAdapter instead. PythonClient.HTTP is not implemented in optimizador.py"
```

**Keep the module** for reference and potential future HTTP endpoint, but remove from `GenerationServer` call sites.

---

## Acceptance Criteria

1. ✅ `PayloadAdapter.build_optimizer_payload/3` correctly translates slot format to Python format
2. ✅ `PayloadAdapter.translate_response/2` correctly translates optimizer response to GenerationServer format
3. ✅ `GenerationServer.run_pipeline/1` calls `OptimizerServer` via `PayloadAdapter` instead of `PythonClient`
4. ✅ `GenerationServer` response includes `recipe_name`, `price_cents`, `macros` from DB lookup
5. ✅ All existing `GenerationServer` tests pass (chat, confirm, reject flows unchanged)
6. ✅ All existing `PlanningService` tests pass (unaffected by this change)
7. ✅ New unit tests for `PayloadAdapter` pass
8. ✅ Full test suite passes (262+ tests)

---

## Non-Goals

- Do NOT modify `PlanningService` — it already works correctly with `OptimizerServer`
- Do NOT modify `optimizador.py` — it works correctly with `OptimizerServer` Port protocol
- Do NOT implement HTTP endpoint in Python — we're using Port/stdio which works
- Do NOT merge `GenerationServer` and `PlanningService` — keep them separate for now