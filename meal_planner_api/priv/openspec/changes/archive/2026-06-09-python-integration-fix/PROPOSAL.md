# SDD Proposal — python-integration-fix

## Elixir-Python Integration Mismatch: Exploration Report

**Change ID:** `python-integration-fix`
**Phase:** proposal
**Date:** 2026-06-09

---

## 1. Discovery: Two Independent Integration Layers

The codebase has **two completely separate optimization integration layers** that were built independently and do not interoperate:

### Layer A — `PythonClient` (HTTP, used by `GenerationServer`)
- Protocol: HTTP POST to `http://localhost:8000/api/v1/optimize-menu`
- Payload format: `{slots: [...], recipe_prices: {...}, recipe_macros: {...}}`
- Called from: `GenerationServer.run_pipeline/1` → `PythonClient.optimize_menu/3`
- Status: **Dead code** — the Python server has no HTTP endpoint at `/api/v1/optimize-menu`

### Layer B — `OptimizerPort/OptimizerServer` (Port/stdio, used by `PlanningService`)
- Protocol: JSON over stdin/stdout (`{"type":"solve","id":"...","payload":{...}}`)
- Payload format: `{days: [...], slots: [...], constraints: {...}, candidates_by_slot: {...}}`
- Called from: `PlanningService.run_optimizer/4` → `OptimizerServer.select_weekly_menu/1`
- Status: **Working** — matches `optimizador.py` exactly

---

## 2. Payload Format Comparison

### Layer A (`PythonClient`) sends:

```elixir
# PythonClient.optimize_menu/3 body:
%{
  "slots" => [
    %{
      "date" => "2026-06-03",
      "slot" => "lunch",
      "available_recipe_ids" => ["1", "2", "3"],
      "constraints" => %{
        "budget_cents" => 5000,
        "protein_g" => 30,
        "max_calories" => 800,
        "excluded_recipe_ids" => [],
        "excluded_ingredients" => ["maní"]
      }
    }
  ],
  "recipe_prices" => %{"1" => 12.50, "2" => 9.50},
  "recipe_macros" => %{"1" => %{protein_g: 25, calories: 450, carbs_g: 30}}
}
```

### Layer B (`OptimizerServer`) sends — which `optimizador.py` expects:

```python
# optimizador.py _validate_payload and _solve reads:
{
  "days": ["2026-06-03", "2026-06-04", ...],
  "slots": ["breakfast", "lunch", "dinner"],
  "constraints": {
    "weekly_budget_cents": 45000,
    "macro_bounds": {
      "protein_g": {"min": 100.0, "max": 150.0},
      "carbs_g": {"min": 225.0, "max": 325.0},
      "fat_g": {"min": 44.44, "max": 77.78}
    }
  },
  "candidates_by_slot": {
    "lunch": [
      {
        "recipe_id": "1",
        "estimated_cost_cents": 12.50,
        "protein_g_per_serving": 25.0,
        "carbs_g_per_serving": 30.0,
        "fat_g_per_serving": 10.0
      }
    ]
  }
}
```

---

## 3. Full Field-by-Field Comparison Table

| Field | PythonClient sends | optimizador.py expects | Match? |
|-------|--------------------|------------------------|--------|
| **Root key 1** | `"slots"` (list of day×slot pairs) | `"days"` (flat date list) | ❌ |
| **Root key 2** | *(no days key)* | `"slots"` (flat slot-type list) | ❌ |
| **Root key 3** | `"recipe_prices"` (map of id→price) | *(not sent separately)* | ❌ |
| **Root key 4** | `"recipe_macros"` (map of id→macros) | *(not sent separately)* | ❌ |
| **Root key 5** | *(no constraints key)* | `"constraints"` (weekly budget + macro_bounds) | ❌ |
| **Root key 6** | *(no candidates key)* | `"candidates_by_slot"` (recipes per slot) | ❌ |
| **Slot structure** | `[{date, slot, available_recipe_ids, constraints}]` | `days: [...], slots: [...], candidates_by_slot: {slot: [...]}` | ❌ |
| **recipe_prices format** | `%{"id" => 12.50}` — string keys, float values | N/A — embedded in candidates | ❌ |
| **recipe_macros format** | `%{"id" => %{protein_g: 25, calories: 450, carbs_g: 30}}` | N/A — embedded as `protein_g_per_serving`, etc. | ❌ |
| **budget_cents** | Per-slot: `"constraints"."budget_cents"` | Weekly total: `"constraints"."weekly_budget_cents"` | ❌ |
| **protein** | Per-slot: `"constraints"."protein_g"` | Weekly aggregate: `"constraints"."macro_bounds"."protein_g"` with `{min, max}` | ❌ |
| **calories** | Per-slot: `"constraints"."max_calories"` | Not present — Python uses protein/carbs/fat only | ❌ |
| **carbs** | Not present | `"constraints"."macro_bounds"."carbs_g"` with `{min, max}` | ❌ |
| **fat** | Not present | `"constraints"."macro_bounds"."fat_g"` with `{min, max}` | ❌ |
| **Protocol** | HTTP POST to `/api/v1/optimize-menu` | JSON line over stdin/stdout with `{"type":"solve",...}` envelope | ❌ |
| **Response format** | `{"slots": [{date, slot, recipe_id, ...}]}` | `{"type":"solution","result":{"meals": [{day, slot, recipe_id}]}}` | ❌ |

---

## 4. Summary of ALL Mismatches

### 4.1 Structure Mismatch (Critical)
- **PythonClient** sends a flat list of slot objects
- **optimizador.py** expects cross-product structure (`days: [...], slots: [...], candidates_by_slot`)

### 4.2 Data Normalization Mismatch (Critical)
- **PythonClient** sends recipe prices/macros as separate maps keyed by recipe ID
- **optimizador.py** expects full candidate objects embedded in `candidates_by_slot`

### 4.3 Constraint Model Mismatch (Critical)
- **PythonClient** sends **per-slot constraints**
- **optimizador.py** enforces **weekly aggregate constraints**

### 4.4 Protocol Mismatch (Critical)
- **PythonClient** uses HTTP POST to non-existent endpoint
- **optimizador.py** uses stdin/stdout JSON line protocol

### 4.5 Response Format Mismatch
- optimizador.py returns only `recipe_id` (not `recipe_name`, `price_cents`, `macros`) — Elixir must resolve these post-optimization

---

## 5. Recommended Fix Approach

### Option C — New `OptimizerPayloadAdapter` module (recommended)

1. Create `lib/meal_planner_api/optimization/payload_adapter.ex` with:
   - `build_optimizer_payload/3` — translates `{slots, recipe_prices, recipe_macros}` → `{days, slots, constraints, candidates_by_slot}`
   - `translate_response/1` — translates `{:ok, %{meals: [...]}}` → `[{date, slot, recipe_id, ...}]`

2. Update `GenerationServer.run_pipeline/1` to call:
   - `PayloadAdapter.build_optimizer_payload/3` → `OptimizerServer.select_weekly_menu/1` → `PayloadAdapter.translate_response/1`

3. Add post-optimization lookup for `recipe_name`, `price_cents`, `macros` from DB

4. Deprecate `PythonClient` (keep for reference, remove from production call sites)

---

## 6. Risk Assessment

| Risk | Level | Mitigation |
|------|-------|-----------|
| GenerationServer refactor breaks chat/modification flows | **High** | Adapter approach isolates changes; state machine unchanged |
| Per-slot → weekly constraints semantic change | **Medium** | Document shift; weekly budget = per-slot × slots-per-day |
| optimizador.py returns no recipe_name/price/macros | **Medium** | Post-optimization lookup from DB |
| excluded_ingredients/excluded_recipe_ids not used by Python | **Medium** | Filter candidates in Elixir before sending |

---

## 7. Key Code Locations

| What | File | Line(s) |
|------|------|---------|
| What GenerationServer builds | `generation/server.ex` | `build_slots_input/1` (lines 301-322) |
| What GenerationServer calls | `generation/server.ex` | line 228 |
| What PriceService fetches | `services/price_service.ex` | `fetch_recipe_prices_float/1` |
| What PythonClient sends | `integrations/python_client.ex` | `optimize_menu/3` body |
| What optimizador.py expects | `optimizador.py` | `_validate_payload` (lines 46-96), `_solve` (lines 98-175) |
| What PlanningService builds | `services/planning_service.ex` | `build_optimization_payload/3` |
| OptimizerPort behaviour | `optimization/optimizer_port.ex` | full file |

---

## 8. Findings Summary

**Root cause:** `GenerationServer` was built against a **straw-man HTTP API** (`PythonClient`) that was never implemented in `optimizador.py`. The actual Python integration uses Port/stdio with a completely different payload structure. Meanwhile, `PlanningService` was built correctly against the real `OptimizerPort` interface.

**Impact:** Every call to `GenerationServer.start_generation/4` fails because:
1. `PythonClient` POSTs to a non-existent HTTP endpoint
2. Even if it reached Python, the payload format would fail validation

**Recommended fix:** New `OptimizerPayloadAdapter` module + replace `PythonClient` call site in `GenerationServer` with `OptimizerServer` call.