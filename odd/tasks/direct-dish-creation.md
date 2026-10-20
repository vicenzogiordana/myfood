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

- [ ] T1 Empty close matches tell the model to stop guessing (decision 2, tool side). Route: inline.
- [ ] T2 Validation-failure notice on a limit cut (decision 3). Route: inline.
- [ ] T3 New message after a limit starts a new run (decision 4). Route: inline.
- [ ] T4 Instructions for decisions 1 and 2 + CHANNELS.md. Route: inline.
- [ ] T5 Full test suite and `mix precommit`; PR.

Route evidence: bounded single worker; each task touches one module plus its test.

## Acceptance criteria

See issue #158: tests for 1–4; instructions updated without contradicting the
budget rule or the "only recipes with X" rule; CHANNELS.md updated; precommit passes.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test158 mix test`
- `mix precommit`

## Progress

- Next step: T1.
