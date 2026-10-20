# Planned Meals scaled to their diners, with guests (issue #152)

Part of spec #93. Locator: `odd/tasks/diner-scaling-and-guests.md`.

## Objective

Every Planned Meal is scaled to its diners: the Household Members present
(minus approved Absence Exceptions) plus that meal's guests. The Purchase,
consumed cost, budget check, confirmation and Projected Pantry all use the
scaled quantities. The agent can set guests per meal, and a guest restriction
the household volunteers is a hard rule for that meal only.

## Problem and why

A live terminal-chat trial (2026-10-20): "burgers on Tuesday lunch with 6
friends" was answered with "cannot plan for more people than the
Household". `Purchase.needs/2` buys one batch of the recipe per meal,
whatever the recipe's servings and the people eating, so a 2-serving recipe
for a 3-member Household is under-bought even without guests.

## Settled product decisions (issue body)

1. Batches = ceil(diners / recipe servings); quantities = recipe quantity x batches.
2. Guests per day+slot through the Workspace; Proposal shows diners; confirmation stores them.
3. Guest cost counts against the same weekly budget (ordinary budget Deviation).
4. Guest restrictions only when the user volunteers them, for that meal only,
   enforced by code. The agent never asks about guest allergies.
5. Nutrition Goal stays Household-only, per standard portion.

## Scope

- New `PlanningAgent.Diners`: diners per meal, batches, guest restrictions
  (parsing, data, per-meal conflict check).
- `Workspace`: `guests` field and `set_guests` edit (releases the proposed meal
  when restrictions change); pins checked against guest restrictions;
  `get_workspace` shows guests.
- `ProposalValidator`: attaches servings; guest-restriction violations.
- `Proposal`: meals carry `diners`, `guests`, `batches`; `meals/1` reads them back.
- `Purchase`: needs scaled by each meal's batches.
- `Tools.run_optimizer`: guest-restricted meals avoid conflicting candidates
  through the existing `avoided_meals` contract (optimizer contract unchanged).
- `Confirmation` + migration: `scheduled_meals.diners`, `scheduled_meals.guests`;
  `selected_quantity` = batches, so the Projected Pantry commits scaled stock.
- `Session.commit` passes guests to revalidation.
- `HouseholdContext.instructions`: household size, guest rules, never ask
  about guest allergies.
- Docs: CONTEXT.md glossary (Diners, Guest), moduledocs.

Out of scope: optimizer cost model, nutrition evaluation, UI.

## Constraints

- Unknown recipe servings (nil) count as one batch; a planned meal is cooked
  at least once (batches >= 1) even when no one is present.
- Guest count 0..50 per meal; guest restrictions are allergen tags or diets.
- Old Workspace snapshots lack `guests`: read with `Map.get/3`.

## Acceptance criteria

- [x] 2-serving recipe, 3-member Household buys 2 batches (test)
- [x] "6 guests Tuesday lunch" scales that meal to 9 diners; Purchase and cost
  reflect it; the Proposal shows the diner count
- [x] An Absence Exception reduces the diners of the meals it covers
- [x] Guest cost over budget is a budget Deviation; approval flow unchanged
- [x] A guest allergy excludes recipes containing it for that meal only, by code
- [x] The agent never asks about guest allergies unprompted (prompt rule + scripted test)
- [x] Confirmed Planned Meals store their diners/guests
- [x] `mix precommit` passes (optimizer contract unchanged, no Python change)

## Tasks

- [x] T1 Diner scaling of the Purchase (members, absences, servings) (route: inline, bounded worker)
- [x] T2 Guests per meal: `set_guests`, Proposal diners, budget, confirmation storage + migration
- [x] T3 Guest restrictions per meal enforced in validator, optimizer candidates and pins
- [x] T4 Prompt rules (no guest-allergy questions), scripted flow test, CONTEXT.md

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test152 mix test`
- `MYFOOD_TEST_DATABASE=meal_planner_api_test152 mix precommit`

## Progress and evidence

- T1-T4 landed in one work unit, commit `f30a034` (they share the new
  `Diners` module; splitting would leave half-wired tool schemas). Route:
  inline in the bounded worker; no delegation (worker may not spawn agents).
- RED observed: `diners_test.exs` 10/12 failing before implementation.
- GREEN: `MYFOOD_TEST_DATABASE=meal_planner_api_test152 mix precommit`:
  1295 passed, 24 skipped, 0 failures.
- `reuse_plan` test updated: reused meals are rescaled to today's diners,
  never the past meal's portions.
- Optimizer contract unchanged (guest restrictions use `avoided_meals`); no
  Python change, so optimizer tests were not run.
- Engram mirror: `odd/diner-scaling-and-guests/tasks`.

## Next step

Review by Jorge el Curioso on the PR, then merge.
