# Optimizer contract (v2)

The OR-Tools optimizer (`optimizador.py` at the repository root) is reached
through the JSON-lines port protocol (`OptimizerPortRunner`). This page is the
contract between the planning code and the solver (spec #93, issues #97, #98 and #99).

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
| `days`, `slots` | The Planning Range: every day × slot that is not skipped gets exactly one meal. Days are a non-empty list of ISO dates (`YYYY-MM-DD`); the planning agent's `run_optimizer` tool sends every date of the Planning Range |
| `candidates_by_slot` | `{slot: [candidate]}`; candidates carry `recipe_id`, `estimated_cost_cents`, per-serving `calories_per_serving`, `protein_g_per_serving`, `carbs_g_per_serving`, `fat_g_per_serving`, `inventory_hit_count`, and `violates_restriction: true` when code found the recipe unsafe for a Member |
| `constraints.weekly_budget_cents` | Budget for the whole range |
| `constraints.macro_bounds` | Optional daily `{min, max}` for `calories`, `protein_g`, `carbs_g`, `fat_g`; built from the Household Nutrition Goal by `MealPlannerApi.Optimization.Contract.nutrition_bounds/1` |
| `constraints.variety_cap` | Optional positive integer, default 2: how many times one recipe may appear in any rolling 7-day window. Adjustable per Planning Session |
| `prior_meals` | Optional fixed context: the confirmed `{day, slot, recipe_id}` Planned Meals of the 6 days before the range, built by code (`MealPlannerApi.Optimization.Variety`). Never returned and never moved |
| `excluded_recipe_ids` | Optional Excluded Recipes |
| `fixed_meals` | Optional `{day, slot, recipe_id}` range meals that never move: Pins and, on a re-optimization, every meal of the previous Proposal that was not released. Each names a range day and slot and a candidate of that slot, at most once per day and slot (otherwise `invalid_fixed_meals`) |
| `avoided_meals` | Optional `{day, slot, recipe_id}` range meals that must not take that recipe (otherwise `invalid_avoided_meals`): a Released Meal the Member asked to change avoids its previous recipe, and a recipe excluded for one run that a fixed meal keeps is avoided on every free meal instead of excluded everywhere. The recipe stays open on every other day and slot; a fixed meal is never avoided |
| `skipped_meals` | Optional `{day, slot}` range meals the Household does not eat at home (issue #160, `edit_workspace` `skip`). They are out of the range: never planned or returned, they count toward no goal (budget, daily nutrition, variety), and a slot skipped on every day needs no candidate. Each names a range day and slot at most once and never a fixed meal (otherwise `invalid_skipped_meals`); an avoided meal there is ignored |
| `time_limit_ms` | Optional solver deadline; Python defaults to 120 000. The planning agent sends none: `MealPlannerApi.PlanningAgent.Optimizer.Port` bounds the whole run with its own deadline (`:timeout_ms`, default 120 s) and the agent's `:solver` call policy, and kills the subprocess when it passes |

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

## Fixed meals

- A fixed meal is never moved and never refused by the variety rules (a Pin
  beats the variety cap), but it counts like a prior meal: free meals of its
  window cannot add more of that recipe, and a free meal on the day before
  or after it in the same slot cannot repeat it.
- Fixed meals count toward the budget and the nutrition goals, so a fixed
  meal that breaks the budget is reported as a Deviation.
- A fixed meal never beats a Restriction or an exclusion: a fixed candidate
  flagged `violates_restriction` or listed in `excluded_recipe_ids` makes the
  reply `infeasible` with `{"cause": "restriction" | "excluded_recipe", "slot": …, "day": …}`.

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
| `infeasible` | A hard rule leaves a slot empty, and `details.causes` names each one: `{"cause": "coverage" \| "restriction" \| "excluded_recipe", "slot": …}` (with `day` when a fixed meal caused it), or `{"cause": "avoided_meal", "slot": …, "day": …}` when an avoided meal has no other candidate; or the variety rules cannot be met: `[{"cause": "variety"}]` |
| `inconclusive` | The deadline passed before any plan was found (`details.reason = "time_limit"`). Never reported as infeasible |
| `invalid_*`, `missing_payload` | Malformed request (including `invalid_variety_cap`, `invalid_prior_meals`, `invalid_fixed_meals`) |
| `solver_unavailable`, `abnormal` | Solver fault |

Elixir callers add the variety part of a request with
`MealPlannerApi.Optimization.Variety.put(payload, Variety.prior_meals(account_id, range_from), cap)`
(the cap comes from the Planning Session, `Variety.default_cap/0` = 2) and interpret replies with
`MealPlannerApi.Optimization.Contract.interpret/1` (a variety infeasibility is
`{:infeasible, [%{cause: :variety, slot: nil}]}`) and classify a validated
Proposal with `MealPlannerApi.Planning.ProposalStatus.classify/2`: any
Deviation makes it `requires_approval`.
