# Planning Session lifecycle hardening

Issue #119, part of spec #93. Branch `feat/issue-119-session-lifecycle-hardening`.

## Objective

Close the lifecycle gaps found in the review of #96 so a Household's
Planning Session slot is never wedged, double-held or bypassed.

## Problem and why

- `Session.init/1` hard-matched `{:ok, _} = Registry.register(...)`: a new
  session started while an old process is still registered for the
  Household (cancel then restart, or a row expired behind a live process
  that has not renewed yet) crashed with `MatchError`.
- A Member who stays connected but does nothing kept the Household's slot
  forever: the absence grace only runs while nobody is connected.
- The legacy `PlanningSessionServer` inserted rows with
  `PlanningRepo.create_session/2`, which only checks range overlap, so a
  legacy session could start beside an agent session.
- The Sweeper's behavior against agent-owned rows had no tests.
- `workspace.proposal` now has a reader (confirmation), and
  `Loop.run_tools/2` kept executing calls after `ask_human` ended the turn.

## Scope

In: session init registration, idle expiry, legacy start vs agent lock,
Sweeper tests for agent rows, post-`ask_human` tool execution, proposal
review. Out: switching the legacy planner off (spec #93, after the battery).

## Constraints

- One Planning Session per Household (spec #93); legacy sessions keep their
  per-range behavior among themselves.
- Tests through public interfaces with fictitious fixtures;
  `MYFOOD_TEST_DATABASE=meal_planner_api_test119`.

## Tasks

- [ ] T1 Restart during an old registration returns `{:error, :session_already_active}` (route: inline, one file + test)
- [ ] T2 Idle expiry: a connected but inactive session ends after `:idle_ms` (default 30 min) and releases the slot (route: inline, one file + test)
- [ ] T3 Legacy start refuses while an agent session holds the Household lock (route: inline; migration + repo + server + tests)
- [ ] T4 Sweeper tests against agent lock rows (route: inline, tests only)
- [ ] T5 No tool call runs after `ask_human` ends the turn; proposal clearing reviewed (route: inline, one file + test)

## Acceptance criteria

- Restart during an old registration returns a typed error, not a `MatchError`
- Idle sessions time out and release the lock
- The legacy session path cannot start while an agent session holds the Household lock
- Sweeper behavior against agent lock rows is covered by tests
- `workspace.proposal` clearing and post-`ask_human` tool execution are reviewed

## Checks

- `MIX_ENV=test MYFOOD_TEST_DATABASE=meal_planner_api_test119 mix test`
- `MYFOOD_TEST_DATABASE=meal_planner_api_test119 mix precommit`

## Progress

Baseline suite run on `origin/main` (79bb2da) before the first change.

## Next step

T1.
