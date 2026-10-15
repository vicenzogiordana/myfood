# Household Nutrition Goal setting

Issue: #95 — Part of spec #93 (user stories 20a, 20b).

## Objective

A Household has one Nutrition Goal in its settings: a daily range of calories and
macros (protein, carbs, fat) per standard portion. Any Member can read and edit it
through the API. A Member's private macro focus stays a Preference and is not a
numeric goal.

## Problem / why

The optimizer needs a clear numeric daily target (calories and macro bounds) owned
by the Household. Today only per-User dietary profiles exist (`macro_goal` is a
qualitative focus), so there is no Household-level numeric goal to plan against.

## Scope

- Persistence: `household_nutrition_goals` table, one row per Household (`accounts`).
- Application: `MealPlannerApi.NutritionGoals` context (`get/1`, `put/2`).
- Delivery: `GET` / `PUT /api/accounts/:account_id/settings/nutrition-goal`.
- Docs: endpoint contract in `meal_planner_api/docs/FRONTEND_INTEGRATION.md`.

Out of scope: wiring the goal into the optimizer or validator (later issues).

## Constraints

- Cross-Household isolation relies on the existing `EnforceAccountScope` plug
  (403 `account_mismatch`).
- Ranges are non-negative integers (kcal, grams); `min <= max`; all four ranges
  are required on update (full replacement).
- The private dietary profile `macro_goal` stays untouched (Preference).

## Acceptance criteria

- [x] Household settings expose and persist a daily calorie range and macro ranges per standard portion
- [x] Any Member of the Household can update it; other Households cannot read or change it
- [x] Invalid ranges (min above max, negative values) are rejected
- [x] Controller tests cover read, update and cross-Household isolation

## Tasks

| ID | Task | Route | Status |
|----|------|-------|--------|
| T1 | Schema + migration + context + controller + routes, test-first via controller tests | inline (single bounded worker; already delegated by parent) | done |
| T2 | Document the endpoint contract | inline (mechanical doc edit) | done |

- [x] T1 — RED observed (route missing → 404/no route), GREEN after implementation. Commit: see "Evidence".
- [x] T2 — docs updated alongside T1 in the same work unit.

## Checks

- `MIX_TEST_PARTITION=95 MYFOOD_TEST_DATABASE=meal_planner_api_test95 mix test test/meal_planner_api_web/controllers/household_nutrition_goal_controller_test.exs`
- `mix test` (full suite) and `mix precommit`

## Evidence

- RED: new controller test file, 13/13 failing with 404 (no route) before the routes existed.
- GREEN: 13/13 passing after implementation.
- Full suite on partition DB `meal_planner_api_test95`: 905 passed, 20 skipped; `mix precommit` exit 0.
- Observed order-dependent flakes unrelated to this change (passed on rerun with the same seed):
  `PlanningCandidateBuilderTest` (`:plan_not_found` in factory setup) and one `PlanningChannelTest` e2e case.
- `config/test.exs` does not append `MIX_TEST_PARTITION` to the DB name; isolation used the existing
  `MYFOOD_TEST_DATABASE` env override instead (no config change).
- T1+T2 commit: `169eff0` `feat(households): add household nutrition goal settings`.

## Next step

Hand the stored goal to the optimizer `macro_bounds` in the planning workspace issues of #93.
