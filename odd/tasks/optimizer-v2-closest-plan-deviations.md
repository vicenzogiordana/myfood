# Optimizer v2: closest plan and Deviations

Issue: #97 — Part of spec #93 (user stories 19–24, 62, 65).

## Objective

The OR-Tools optimizer always returns the closest plan plus an exact per-goal
Deviation report instead of failing when goals conflict. Infeasibility names its
cause, a solver timeout is inconclusive, optimality is disclosed, and a Proposal
with Deviations is classified as requiring approval.

## Problem / why

Today `optimizador.py` treats budget and daily macro bounds as hard constraints:
conflicting goals produce an opaque `infeasible` error (`budget_too_low`,
`no_recipe_for_slot`, `hard_constraints_unsatisfiable`). There is no solver time
limit, no optimality disclosure, no Deviation report and no link to the Household
Nutrition Goal (#95).

## Scope

- `optimizador.py` (port boundary): soft budget / daily calories / daily macros
  relaxed lexicographically (budget > calories > macros); hard coverage,
  Restriction-flagged candidates and excluded recipes; named infeasibility
  causes; solver time limit with `inconclusive` timeouts; `optimality` status.
  Backend choice (SCIP via `pywraplp`) documented in the module.
- `requirements.txt`: pin the OR-Tools version.
- Elixir: `MealPlannerApi.Optimization.Contract` (Nutrition Goal → daily bounds,
  typed interpretation of optimizer results) and
  `MealPlannerApi.Planning.ProposalStatus` (valid / requires_approval / invalid).
- Docs: `meal_planner_api/docs/OPTIMIZER_CONTRACT.md`.

Out of scope: variety rules (#98), pins/released meals (#99), Deviation Approval
(#103), package-aware purchase cost. The agent tools `run_optimizer` /
`present_proposal` live in the unmerged tracer bullet (#96, PR #114); this slice
ships the seam they call (see "Integration note").

## Constraints

- Only budget, daily calories and daily macros relax; Restrictions, excluded
  recipes and full coverage never relax.
- Timeouts are never reported as infeasible.
- Legacy flow keeps the `"meals"` result shape; its own validator still rejects
  plans outside its hard bounds (fails closed).

## Acceptance criteria

- [x] Conflicting goals return a plan plus exact Deviations (budget exceeded by an amount, a day's calories below minimum)
- [x] Relaxation order budget > calories > macros is observable in port-contract tests
- [x] Infeasible results name their cause (Restriction, excluded recipe, coverage)
- [x] Timeouts are reported as inconclusive, never as infeasible
- [x] Optimality status is reported
- [x] OR-Tools version is pinned and the chosen backend is documented in the code
- [x] Proposals with Deviations are presented as requiring approval (classification seam; tool wiring pending #114, see note)

## Tasks

| ID | Task | Route | Status |
|----|------|-------|--------|
| T1 | Python optimizer v2 + port-contract tests + OR-Tools pin | inline (bounded worker; single writer) | done |
| T2 | Elixir contract + ProposalStatus + docs, test-first | inline (bounded worker; single writer) | done |

- [x] T1 — RED: 24 tests, 5 failures + 15 errors (no `deviations`/`optimality`, budget hard, no `_create_solver`). GREEN: 24/24 OK.
  Refactor: a 90-meal range first hit the 120 s deadline because a met goal was frozen as one summed
  constraint coupling every day; freezing met goals per deviation variable brought it to ~15 s.
- [x] T2 — RED: 0/13 (`Contract`/`ProposalStatus` undefined). GREEN: 13/13. A real-port test
  (`contract_port_test.exs`, runs when `OPTIMIZER_PYTHON` is set) passes 2/2 against `optimizador.py`.

## Review round 1 (Jorge el Curioso, PR #115)

| ID | Task | Route | Status |
|----|------|-------|--------|
| R1 | `Contract.interpret/1` reaches `infeasible`/`inconclusive` through real `OptimizerServer` replies | inline (bounded worker; single writer) | done |

- [x] R1 — Finding: `OptimizerServer` replies `{:error, {:infeasible, details}}` and mapped
  `inconclusive` to `:optimizer_error`, so `Contract.interpret/1` only ever returned
  `{:error, :optimizer_error}` for them on the server path; both verdicts also counted toward
  the circuit breaker. Fix: `interpret/1` accepts the server's `{:error, {reason, details}}`
  shape; `normalize_optimizer_error/2` preserves `{:inconclusive, details}`; `handle_error_frame`
  no longer counts `infeasible`/`inconclusive` (healthy solver verdicts) as failures.
  RED: 3 new `optimizer_server_test.exs` tests failed (16/19; two returned
  `{:error, :optimizer_error}`, the circuit test hit the open-circuit fallback). GREEN: 19/19.

## Integration note

`run_optimizer` should pass `Contract.nutrition_bounds(NutritionGoals.get(account_id))`
as `constraints.macro_bounds` and interpret the reply with `Contract.interpret/1`
(`OptimizerServer` now passes `inconclusive` through as `{:inconclusive, details}`; the #114
port adapter must do the same instead of mapping it to `:optimizer_error`);
`present_proposal` should emit `ProposalStatus.classify(violations, deviations)`.
Wire this in whichever of #96/#97 merges second.

## Checks

- `.venv-ortools/bin/python -m unittest test_optimizador` (repo root)
- `MIX_TEST_PARTITION=97 MYFOOD_TEST_DATABASE=meal_planner_api_test97 mix test`
- `mix precommit`

## Evidence

- T1 commit: `6b9ba4c` feat(optimizer): return closest plan with prioritized deviations
- T2 commit: the `feat(planning)` commit that follows T1 on this branch
- Python: `.venv-ortools/bin/python -m unittest test_optimizador` → 24 tests OK
- `mix precommit` (partitioned DB, `OPTIMIZER_PYTHON` set) → 938 passed, 20 skipped
- R1 commit: the `fix(optimizer)` commit that follows T2 on this branch
- R1: `mix test` and `mix precommit` (partitioned DB, `OPTIMIZER_PYTHON` set) → 941 passed, 20 skipped
- Note: `config/test.exs` does not append `MIX_TEST_PARTITION` to the DB name; isolation
  comes from `MYFOOD_TEST_DATABASE=meal_planner_api_test97`.
