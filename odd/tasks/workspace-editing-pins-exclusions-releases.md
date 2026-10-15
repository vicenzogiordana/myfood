# Workspace editing: Pin, Excluded Recipe, Released Meal

Issue: #99 — Part of spec #93 (user stories 27, 29–34, 69, 102).

## Objective

A Member steers a Proposal conversationally. Through `edit_workspace` the agent Pins
recipes to a day and slot, adds Excluded Recipes, changes the variety cap and Releases
meals; `get_workspace` reads the Workspace back. `run_optimizer` repairs only the Released
Meals of the previous Proposal and keeps every other meal fixed; "redo the whole week"
releases everything. Pins beat the variety cap but never a Restriction, and a Pin that
breaks the budget shows up as a Deviation.

## Problem / why

The tracer bullet (#96) re-plans the whole range on every `run_optimizer` call and has no
Workspace state beyond the draft and the last Proposal, so "keep Monday's dinner" or
"change only Thursday" cannot be honoured.

## Scope

- Optimizer: `fixed_meals` in the request (Pins and kept meals). Fixed meals beat the
  variety rules, count toward budget and nutrition (a Deviation when they break them) and
  never beat a Restriction or an exclusion.
- `MealPlannerApi.PlanningAgent.Workspace`: Pins, Excluded Recipes, Released Meals,
  variety cap, draft and Proposal, with validated edits that return a reason when refused.
- Tools `edit_workspace` (pin, unpin, exclude, include, release, release_all,
  set_variety_cap) and `get_workspace`; approvals are refused by code.
- `run_optimizer` sends fixed meals, Excluded Recipes, the variety cap and prior meals, and
  rejects an optimizer reply that moved a fixed meal.
- Spend and token caps scoped per Planning Session (product decision of 2026-10-15: the
  caps bound the OpenAI calls of the whole Planning Session, not of one request).

Out of scope: chat-scoped brands (pricing slice), Deviation Approval and the
`requires_approval` status (approval slice), real package costs (purchase slice; until then
candidate costs are 0, so a budget Deviation from a Pin is proven at the optimizer level).

## Constraints

- Household always from the session; Restriction conflicts explained generically.
- Tests through public interfaces (Session, optimizer port protocol) with fictitious fixtures.
- Delivery strategy: `single-pr` (pipeline asks one PR per issue).

## Acceptance criteria

- [x] Pins, exclusions, releases and variety cap changes are stored in the Workspace and visible via get_workspace
- [x] Invalid edits are rejected with a reason; approvals cannot be set through edit_workspace
- [x] Re-optimization changes only Released Meals
- [x] A Pin conflicting with a Restriction is refused and the agent offers a safe replacement
- [x] Session tests show a two-meal refinement leaves the other meals untouched

## Tasks

| ID | Task | Route | Status |
|----|------|-------|--------|
| T1 | Optimizer `fixed_meals` (Python + contract doc) | inline (bounded worker, no sub-delegation) | done (`4ff807a`) |
| T2 | Workspace module, `edit_workspace` and `get_workspace` tools | inline | done (`e361fb4`, one work unit with T3: same test file and tool seam) |
| T3 | `run_optimizer` over the Workspace: fixed meals, exclusions, variety cap, release_all, two-meal refinement | inline | done (`e361fb4`) |
| T4 | Spend and token caps per Planning Session (docs + cross-turn test) | inline | done (`d93a3b3`) |

## Checks

- `../.venv-ortools/bin/python -m unittest test_optimizador`
- `MIX_TEST_PARTITION=99 MYFOOD_TEST_DATABASE=meal_planner_api_test_99 mix test`
- `MIX_TEST_PARTITION=99 MYFOOD_TEST_DATABASE=meal_planner_api_test_99 mix precommit`

## Evidence

- `config/test.exs` does not append `MIX_TEST_PARTITION` to the database name; isolation
  uses the existing `MYFOOD_TEST_DATABASE` override (`meal_planner_api_test_99`).
- T1 RED: `FixedMealTests` 9 tests, 6 failures + 8 errors (subtests); a tie-break
  expectation was relaxed and a free-before-fixed consecutive case added (RED 1 failure);
  GREEN: full Python suite 55/55.
- T2+T3 RED: `session_workspace_test.exs` 0/12 with the implementation stashed; GREEN 12/12.
  Planning agent + channel tests 82/82.
- T4: the ledger already lived in the model state created once per session, so the new
  test "spend and token caps bound the whole Planning Session, not one request" passed on
  first run (characterization of the 2026-10-15 decision, no RED); docs and moduledocs now
  say "per Planning Session" instead of "per execution".
- Full: `MIX_TEST_PARTITION=99 MYFOOD_TEST_DATABASE=meal_planner_api_test_99 mix precommit`
  exit 0, 1034 passed, 25 skipped; no warnings from changed files (remaining warnings are
  pre-existing in unrelated tests).

## Decisions

- `release_all` ("redo the whole week") releases every meal that is not pinned; Pins last
  for the whole Planning Session (glossary) and are reported as `still_pinned`.
- Excluding a recipe that is in the last Proposal releases those meals (reported), since an
  excluded recipe cannot stay fixed.
- Kept (not released) meals beat the variety cap like Pins, because only Released Meals may
  change; the agent can release more after asking.
- Code checks that the optimizer kept every fixed meal (`fixed_meal_moved` otherwise).
