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

- [x] T1 Restart during an old registration returns `{:error, :session_already_active}` (route: inline, one file + test)
- [x] T2 Idle expiry: a connected but inactive session ends after `:idle_ms` (default 30 min) and releases the slot (route: inline, one file + test)
- [x] T3 Legacy start refuses while an agent session holds the Household lock (route: inline; migration + repo + server + tests)
- [x] T4 Sweeper tests against agent lock rows (route: inline, tests only)
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

- T1 commit 1b26822. RED: `session_test.exs` new test failed with the
  `MatchError` wrapped in the start error; GREEN: session + recovery tests
  33 passed.
- T2: RED: the three idle tests in `session_grace_test.exs` failed (no
  `session_ended`); GREEN: `test/meal_planner_api/planning_agent/` 234 passed.
  Default idle time 30 minutes (configurable `:idle_ms`), glossary term
  "Idle Expiry" added to CONTEXT.md. Commit 02013c2.
- T3: chose "respect the lock" over removal (the legacy planner is still on
  until the battery passes). Rows get an `agent` marker (migration
  `20261015160000`); `PlanningRepo.create_legacy_session/2` takes the same
  advisory lock and refuses with `:session_already_active` while an agent
  row is active; legacy rows keep their per-range rule. RED: the new
  `legacy_session_agent_lock_test.exs` start returned `{:ok, _}`; GREEN:
  generation, channels, planning repo and migration shape tests 234 passed.
  Commit 5cd0d19.
- T4: inspection found the Sweeper correct for agent rows (a present
  session's lease covers >= 120 s and renews every 30 s; an absent one's
  lease is its grace deadline; expiry deletes the recovery snapshot; a live
  process whose row was swept stops on its next renewal). Test-first
  exception: characterization tests, no RED possible; teeth checked by a
  mutation (Sweeper ignoring the lease) that failed 3 of 4. GREEN:
  `session_sweeper_test.exs` 4 passed.

## Next step

T5.
