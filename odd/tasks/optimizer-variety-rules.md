# Optimizer variety rules

Issue: #98 — Part of spec #93 (user stories 22, 25–28). Builds on #97 (optimizer v2).

## Objective

Plans are varied by hard rule: a recipe appears at most `variety_cap` times (default 2)
in any rolling 7-day window, and never on consecutive days in the same meal slot. The
confirmed Planned Meals of the 6 days before the Planning Range are passed by code as
fixed context, so the windows and the consecutive-day rule cross the range boundary.
Variety never relaxes: when it cannot be met the result is `infeasible` with cause
`variety`.

## Problem / why

`optimizador.py` (v2, #97) has no notion of repetition: with one cheap recipe it fills
the whole range with it. Nothing reads the Calendar before the range, so a new range can
repeat what was just eaten.

## Scope

- `optimizador.py`: `prior_meals` payload field, `constraints.variety_cap`, rolling
  7-day cap and consecutive-slot rule as hard MIP constraints, `variety` infeasibility
  cause; days must be ISO dates. Port-contract tests in `test_optimizador.py`.
- Elixir: `MealPlannerApi.Optimization.Variety` (default cap, 6-day prior context from
  confirmed scheduled meals, payload builder validating the cap) and `Contract`
  interpreting the `variety` cause.
- Docs: `meal_planner_api/docs/OPTIMIZER_CONTRACT.md`.

Accepted change during T1: the solver backend moved from SCIP to CP-SAT (same
`pywraplp` wrapper). With the variety rules, SCIP stopped at a 60 s budget on the
spec's ~90-meal range still 10 kcal short of a reachable calorie goal; CP-SAT met every
goal in about 17 s. The tie-break became its own exact stage because CP-SAT's
coefficient scaling dropped the `index / 1e6` term.

Out of scope: storing the cap in the Workspace / chat tool to change it (Workspace lives
in the unmerged tracer bullet #96 / PR #114; see "Integration note"), Pins beating the
cap (#99).

## Constraints

- Variety never relaxes; only budget, calories and macros do (#97 policy unchanged).
- Prior meals are fixed context: they are never returned and never moved.
- A prior window already above the cap does not make the range infeasible by itself;
  the range simply cannot add more of that recipe in that window.

## Acceptance criteria

- [x] Rolling 7-day cap is enforced across the range and the 6-day prior context
- [x] No recipe repeats on consecutive days in the same slot, including across the range boundary
- [x] The cap is adjustable per session and honoured (request field + Elixir builder; Workspace wiring pending #114)
- [x] Unsatisfiable variety yields infeasible with cause variety
- [x] Port-contract tests cover each rule

## Tasks

| ID | Task | Route | Status |
|----|------|-------|--------|
| T1 | Python variety rules + port-contract tests | inline (bounded worker; single writer) | done |
| T2 | Elixir `Variety` context/builder + `Contract` variety cause + docs, test-first | inline (bounded worker; single writer) | done |

## Checks

- `/Users/vicenzogiordana/Desktop/Prog/broski/myfood-worktrees/.venv-ortools/bin/python -m unittest test_optimizador` (repo root)
- `MIX_TEST_PARTITION=98 MYFOOD_TEST_DATABASE=meal_planner_api_test98 mix test`
- `mix precommit`

## Evidence

- [x] T1 — RED: 44 tests, 12 failures + 11 errors, all in the 20 new variety tests
  (old 24 green). GREEN: 44/44 OK (three consecutive runs, ~21 s). Refactor: SCIP → CP-SAT
  (see above); the 90-meal scale test now also asserts both variety rules.
  Commit: `4593fc2` feat(optimizer): enforce variety rules with prior-meal context.
- [x] T2 — RED: `mix test test/meal_planner_api/optimization` → 57/65 (Variety undefined,
  `variety` cause rejected). GREEN: 65/65, including 2 new real-port tests
  (`OPTIMIZER_PYTHON` set). Commit: the `feat(planning)` commit after T1 on this branch.
- `mix precommit` (partitioned DB, `OPTIMIZER_PYTHON` set) → 953 passed, 20 skipped.
  One earlier full run reported 950/953; `mix test --failed` passed 3/3 and three later
  full runs passed 953/953, so those 3 were intermittent and not reproduced.
- Note: `config/test.exs` does not append `MIX_TEST_PARTITION` to the DB name; isolation
  comes from `MYFOOD_TEST_DATABASE=meal_planner_api_test98`.

## Integration note

The Workspace (#96 / PR #114) should hold `variety_cap` (start at
`Variety.default_cap/0`, change it from the chat), and `run_optimizer` should build its
payload with `Variety.put(payload, Variety.prior_meals(account_id, range_from), cap)`.
Pins beating the cap are #99.
