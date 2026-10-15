# Optimizer contract (v2)

The OR-Tools optimizer (`optimizador.py` at the repository root) is reached
through the JSON-lines port protocol (`OptimizerPortRunner`). This page is the
contract between the planning code and the solver (spec #93, issue #97).

## Solver

- Backend: SCIP through `ortools.linear_solver.pywraplp`.
- OR-Tools version: pinned in `requirements.txt` (`ortools==9.15.6755`).
- Install for local runs: `python3 -m venv <venv outside the repo>` and
  `<venv>/bin/pip install -r requirements.txt`; point `OPTIMIZER_PYTHON` at it.

## Request (`payload`)

| Field | Meaning |
|---|---|
| `days`, `slots` | The Planning Range: every day × slot gets exactly one meal |
| `candidates_by_slot` | `{slot: [candidate]}`; candidates carry `recipe_id`, `estimated_cost_cents`, per-serving `calories_per_serving`, `protein_g_per_serving`, `carbs_g_per_serving`, `fat_g_per_serving`, `inventory_hit_count`, and `violates_restriction: true` when code found the recipe unsafe for a Member |
| `constraints.weekly_budget_cents` | Budget for the whole range |
| `constraints.macro_bounds` | Optional daily `{min, max}` for `calories`, `protein_g`, `carbs_g`, `fat_g`; built from the Household Nutrition Goal by `MealPlannerApi.Optimization.Contract.nutrition_bounds/1` |
| `excluded_recipe_ids` | Optional Excluded Recipes |
| `time_limit_ms` | Optional solver deadline, default 120 000 |

## Goal policy

- The optimizer always returns the closest plan.
- Only the budget, daily calories and daily macros relax, in the fixed
  priority **budget > calories > macros**. Priority is exact: each goal is
  solved to its optimum and frozen before the next, so a lower goal never buys
  any amount of a higher one.
- Full coverage, Restriction-flagged candidates and Excluded Recipes never
  relax.

## Replies

Solution:

```json
{"type": "solution", "id": "…", "result": {
  "meals": [{"day": "2026-09-07", "slot": "lunch", "recipe_id": "…"}],
  "deviations": [
    {"goal": "budget", "priority": 1, "direction": "above_max", "bound": 100, "actual": 250, "amount": 150},
    {"goal": "calories", "priority": 2, "day": "2026-09-07", "direction": "below_min", "bound": 1000, "actual": 400, "amount": 600}
  ],
  "optimality": "optimal"
}}
```

- `deviations` lists every Deviation with its exact amount, ordered by
  priority (budget 1, calories 2, macros 3) and then day. Empty means every
  goal is met.
- `optimality` is `optimal` (proven) or `feasible` (deadline reached with a
  usable plan that is not proven optimal; disclose it to the Member).

Errors (`{"type": "error", "error": …, "details": …}`):

| `error` | Meaning |
|---|---|
| `infeasible` | A hard rule leaves a slot empty. `details.causes` names each one: `{"cause": "coverage" \| "restriction" \| "excluded_recipe", "slot": …}` |
| `inconclusive` | The deadline passed before any plan was found (`details.reason = "time_limit"`). Never reported as infeasible |
| `invalid_*`, `missing_payload` | Malformed request |
| `solver_unavailable`, `abnormal` | Solver fault |

Elixir callers interpret replies with
`MealPlannerApi.Optimization.Contract.interpret/1` and classify a validated
Proposal with `MealPlannerApi.Planning.ProposalStatus.classify/2`: any
Deviation makes it `requires_approval`.
