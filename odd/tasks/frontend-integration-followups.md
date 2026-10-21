# Final follow-ups before frontend integration (issue #173)

Locator: `odd/tasks/frontend-integration-followups.md`. Part of spec #93.
Engram mirror: `odd/frontend-integration-followups/tasks`.

## Objective

Leave main clean for the frontend integration: the planning channel never
crashes when a Session dies mid-call, the documented client contract matches
the code, a fallbacks misconfiguration is refused at init, legacy docs stop
presenting retired modules as current, and the terminal chat dev tool is
safer.

## Problem and why

Jorge follow-ups from #170, #171 and #172. The frontend relies on the
documented channel contract (`docs/CHANNELS.md`), so drift or a channel
crash would surface as client bugs.

## Scope (authorized)

Issue #173 items 1 to 6, in `meal_planner_api/lib`, `test`, `docs`.
Out of scope: frontend code, new channel events.

## Constraints

- Tests through public interfaces with fictitious fixtures.
- Tests run with `MYFOOD_TEST_DATABASE=meal_planner_api_test173`.
- Conventional Commits, no AI attribution.

## Checklist

- [x] T1. Channel robustness: `Session.confirm/3` and `Session.human_action/2`
  map every `:exit` to a typed refusal (timeout: `unresolved` for confirm,
  `busy` for approvals; any other exit: replay lookup for confirm,
  `session_not_active` for approvals). Test: the session is killed while the
  channel waits on the call; structured error reply and the channel is alive.
  Route: inline (2 files, understood).
- [x] T2. Bound `parse_meals/1`: at most `31 days x 4 known slots` meals,
  built with prepend plus `Enum.reverse`. Test: an oversized list is
  `invalid_absence_exception`. Route: inline.
- [x] T3. Contract accuracy: membership check in `Session.replayed`
  (a replay answers only the Member who confirmed it), `internal_error` in
  the channel moduledoc's confirm reasons, CHANNELS.md aligned. Route: inline.
- [x] T4. `ClaudeMessages.init` refuses `fallbacks: true` on a
  `claude-haiku-*` model with `{:error, :fallbacks_unsupported}`. Route: inline.
- [x] T5. Legacy docs drift: annotate PlanningCandidateBuilder lines in
  `CONVERSATIONAL_MEAL_PLAN_SPEC.md`; restore the PLANNING_CHAT.md pointer in
  `QUALITY_BATTERY.md`. Route: inline (passive docs).
- [x] T6. Terminal chat hardening: `--reset` only on a `*_chat` database;
  `Household.seed` inside `Repo.transaction`; `:exit` caught around the
  Repl's bare Session calls so the spend summary prints; one chat per
  database documented. Route: inline.

## Acceptance criteria

- A test covers each code item (T1 to T4, T6).
- `mix precommit` passes.

## Checks

- Focused: `mix test <files>` per task.
- Closure: `MYFOOD_TEST_DATABASE=meal_planner_api_test173 mix test`, `mix precommit`.

## Delivery

Strategy `single-pr` (forecast well under 400 authored lines).

## Progress and evidence

- T1, T2, T3: commit `880342b`. RED observed (6 new channel tests failing),
  GREEN: channel + contract + session confirm/approval tests 133 passed.
  The confirm timeout branch (60 s) is covered by reasoning only; the
  approval timeout branch has a 5 s test.
- T4: commit `224b87d`. RED 55/56, GREEN model + battery + runtime config 160 passed.
- T6: commit `2083159`. RED 4/7, GREEN 7 passed. Manual smoke: scripted chat
  on a throwaway `*_chat` database seeded, planned and reset; `--reset` on
  `meal_planner_api_test173` refused without truncating.
- T5: commit `d290fa1` (passive docs, structural readback).
- Closure: `mix precommit` with `MYFOOD_TEST_DATABASE=meal_planner_api_test173`:
  1438 passed, 24 skipped. Baseline before changes had 1 flaky failure that
  passed on `--failed` rerun.

## Next step

Push, open the PR (Closes #173, Part of #93), Jorge review, merge.
