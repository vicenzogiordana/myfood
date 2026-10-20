# Direct dish creation, missing ingredients and messages after a limit (issue #158)

Part of spec #93. Locator: `odd/tasks/direct-dish-creation.md`; Engram mirror `odd/direct-dish-creation/tasks`.

## Objective

Make the planning agent robust on Haiku 5.5 when the household asks for a dish no
recipe provides: create it directly (and say it is AI-created), stop guessing
ingredient names the catalog does not have, tell the Member in code why a run
was cut by repeated validation failures, and accept the Member's next message
after a limit instead of refusing it.

## Problem

Live trial (2026-10-20): the pizza request retried `create_recipe` four times
with guessed ingredient names, all `unknown_ingredients` with empty
`close_matches`; `no_progress` cut the run with no Proposal and no message; the
next message was refused with `authorization_required`.

## Scope

- `RecipeDraft`: `unknown_ingredients` result names ingredients with no close
  match and tells the model to stop guessing (decision 2).
- `HouseholdContext.instructions/3`: create an explicitly requested dish directly,
  disclose AI creation; missing ingredient handling; budget and "only recipes with
  X" rules unchanged (decisions 1, 2).
- `Loop.finish/2`: code-rendered notice for limits cut by repeated validation
  failures of one tool (decision 3).
- `Session.send_message/2`: a new message after a reached limit implicitly
  authorizes the continuation; session ceilings still apply (decision 4).
- `docs/CHANNELS.md`.

## Constraints

- Tool output never reaches instructions; the notice only uses code-defined kinds
  and the names the model itself sent, bounded.
- Session ceilings and spend/token caps (#154) are never extended.

## Tasks

- [x] T1 Empty close matches tell the model to stop guessing (decision 2, tool side). Route: inline. RED→GREEN in recipe_tools_test. Commit 741e586.
- [x] T2 Validation-failure notice on a limit cut (decision 3). Route: inline. RED→GREEN in session_bounds_test (the fixed-meal test now expects a non-blaming notice). Commit 3e44a77.
- [x] T3 New message after a limit starts a new run (decision 4). Route: inline. RED→GREEN in session_bounds_test and planning_agent_channel_test; battery runner no longer halts on authorization_required. Commit e68e4f1.
- [x] T4 Instructions for decisions 1 and 2 + CHANNELS.md. Route: inline. RED→GREEN in household_context_test. Commit 6baddc2.
- [x] T5 Full test suite (1336 passed, 24 skipped) and `mix precommit` (passed); PR opened.

Route evidence: bounded single worker; each task touches one module plus its test.

## Acceptance criteria

See issue #158: tests for 1–4; instructions updated without contradicting the
budget rule or the "only recipes with X" rule; CHANNELS.md updated; precommit passes.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test158 mix test`
- `mix precommit`

## Progress

- All tasks done. Next step: Jorge el Curioso review on the PR, then merge.
- Note: no edit_workspace action leaves a meal empty, so "leave that meal for the household" means the plan keeps an existing recipe there and the agent says so.
