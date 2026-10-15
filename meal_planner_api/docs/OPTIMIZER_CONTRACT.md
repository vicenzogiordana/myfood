# Optimizer contract (v2)

The OR-Tools optimizer (`optimizador.py` at the repository root) is reached
through the JSON-lines port protocol (`OptimizerPortRunner`). This page is the
contract between the planning code and the solver (spec #93, issues #97 and #98).

## Solver

- Backend: CP-SAT through `ortools.linear_solver.pywraplp`. It replaced SCIP
  with the variety rules (#98): on a 90-meal range SCIP stopped at 60 s still
  short of a reachable calorie goal, while CP-SAT meets every goal in about
  17 s. The wrapper scales fractional coefficients itself; reported
  Deviations are always recomputed exactly from the chosen recipes.
- OR-Tools version: pinned in `requirements.txt` (`ortools==9.15.6755`).
- Install for local runs: `python3 -m venv <venv outside the repo>` and
  `<venv>/bin/pip install -r requirements.txt`; point `OPTIMIZER_PYTHON` at it.

## Request (`payload`)

| Field | Meaning |
|---|---|
| `days`, `slots` | The Planning Range: every day × slot gets exactly one meal. Days are a non-empty list of ISO dates (`YYYY-MM-DD`); `PlanningService` turns weekday names into the dates of the upcoming range before sending them |
| `candidates_by_slot` | `{slot: [candidate]}`; candidates carry `recipe_id`, `estimated_cost_cents`, per-serving `calories_per_serving`, `protein_g_per_serving`, `carbs_g_per_serving`, `fat_g_per_serving`, `inventory_hit_count`, and `violates_restriction: true` when code found the recipe unsafe for a Member |
| `constraints.weekly_budget_cents` | Budget for the whole range |
| `constraints.macro_bounds` | Optional daily `{min, max}` for `calories`, `protein_g`, `carbs_g`, `fat_g`; built from the Household Nutrition Goal by `MealPlannerApi.Optimization.Contract.nutrition_bounds/1` |
| `constraints.variety_cap` | Optional positive integer, default 2: how many times one recipe may appear in any rolling 7-day window. Adjustable per Planning Session |
| `prior_meals` | Optional fixed context: the confirmed `{day, slot, recipe_id}` Planned Meals of the 6 days before the range, built by code (`MealPlannerApi.Optimization.Variety`). Never returned and never moved |
| `excluded_recipe_ids` | Optional Excluded Recipes |
| `time_limit_ms` | Solver deadline. Python defaults to 120 000, but `OptimizerServer` always sends one below its own timeout (`optimizer_timeout_ms` minus up to 1.5 s) and clamps larger caller values, so slow solves end as `inconclusive` or a feasible incumbent instead of an Elixir timeout |

## Goal policy

- The optimizer always returns the closest plan.
- Only the budget, daily calories and daily macros relax, in the fixed
  priority **budget > calories > macros**. Priority is exact: each goal is
  solved to its optimum and frozen before the next, so a lower goal never buys
  any amount of a higher one.
- Full coverage, Restriction-flagged candidates, Excluded Recipes and the
  variety rules never relax.

## Variety rules

- **Rolling cap**: in every 7 consecutive days a recipe appears at most
  `variety_cap` times, counting every slot and the prior meals in that
  window. When the prior meals alone already reach the cap, the range simply
  cannot add that recipe to the window.
- **No consecutive repeats**: a recipe never fills the same slot on two
  consecutive days, including the last prior day and the first range day.
  Different slots on consecutive days are allowed.
- When no plan satisfies them the reply is `infeasible` with the single cause
  `{"cause": "variety"}`.

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
| `infeasible` | A hard rule leaves a slot empty, and `details.causes` names each one: `{"cause": "coverage" \| "restriction" \| "excluded_recipe", "slot": …}`; or the variety rules cannot be met: `[{"cause": "variety"}]` |
| `inconclusive` | The deadline passed before any plan was found (`details.reason = "time_limit"`). Never reported as infeasible |
| `invalid_*`, `missing_payload` | Malformed request (including `invalid_variety_cap`, `invalid_prior_meals`) |
| `solver_unavailable`, `abnormal` | Solver fault |

Elixir callers add the variety part of a request with
`MealPlannerApi.Optimization.Variety.put(payload, Variety.prior_meals(account_id, range_from), cap)`
(the cap comes from the Planning Session, `Variety.default_cap/0` = 2) and interpret replies with
`MealPlannerApi.Optimization.Contract.interpret/1` (a variety infeasibility is
`{:infeasible, [%{cause: :variety, slot: nil}]}`) and classify a validated
Proposal with `MealPlannerApi.Planning.ProposalStatus.classify/2`: any
Deviation makes it `requires_approval`.
