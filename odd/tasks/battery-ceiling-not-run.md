# Battery: runs skipped by the spend ceiling are not run (issue #145)

Part of spec #93. Locator: `odd/tasks/battery-ceiling-not-run.md`.

## Objective

When the battery spend ceiling is exhausted, the remaining runs are reported
as not run and the verdict is `incomplete`, as `docs/QUALITY_BATTERY.md` and
the `Battery` moduledoc promise. Today they are graded `incorrect`.

## Problem and why

Battery run 2026-10-19: after the ceiling was spent during A5, the remaining
ceiling was positive but below one call's reservation. Every later run
started a session whose first model call was refused (`agent_unavailable`
with reason `spend_cap_reached`, 0 micro-USD, 0-2 ms), and was graded
`incorrect`. The report said `Not run: 0` and `FAIL`, and the escalation and
recovery gates were computed on runs that never reached the model.

`Battery.run/2` only stops when the remaining ceiling is exactly zero, and
`Run.execute/3` grades every run it executes.

## Scope

- `Battery.run/2`: tell each run whether its per-session spend cap was
  lowered by the ceiling; stop the battery after a run the ceiling cut.
- `Battery.Run`: a run whose model call is refused with `spend_cap_reached`
  while its cap is the remaining ceiling is recorded `not_run`, never graded.
- `Battery.Report`: `not_run` results do not count as runs, do not feed
  gates or the score, and their spend still counts in the total; the verdict
  is `incomplete` whenever any planned run did not run.
- Docs: `docs/QUALITY_BATTERY.md`, moduledocs.

Out of scope: the session, the model adapters, the spend ledger.

## Constraints

- Offline tests only; no provider call.
- A run that reaches the adapter's own configured per-session cap (the
  ceiling not binding) is genuine agent behavior and stays graded.

## Acceptance criteria

- [x] A run whose model call is refused because the remaining ceiling is zero
  (or below one call's reservation) is recorded as not run, never graded
- [x] The verdict is `incomplete` whenever any planned run did not run, and
  gates computed only from runs that ran (gates without evidence stay not
  measured)
- [x] Offline test reproducing the 2026-10-19 shape: a ceiling that runs out
  mid-battery
- [x] Report Summary shows the Not run count correctly

## Tasks

- [x] T1 (route: inline, one module pair plus tests; no mapping trigger)
  Record ceiling-cut runs as not run, stop the battery there, exclude them
  from the report's counts and gates, make `incomplete` win the verdict,
  docs. Test-first: RED observed on the new battery and report tests.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test145 mix test`
- `MYFOOD_TEST_DATABASE=meal_planner_api_test145 mix precommit`

## Progress

- T1: see commit evidence below.

## Evidence

- RED: 5 of the new/updated battery and report tests failed before the
  change (the mid-battery test ran 6 runs instead of 2, the 2026-10-19
  bug); the own-cap guard test passed before and after.
- GREEN: battery, report and mix task tests 41 passed; full suite 1460
  passed, 25 skipped; `mix precommit` exit 0.
- Engram mirror: saved under `odd/battery-ceiling-not-run/tasks`.
- T1 commit: the `fix(planning-agent)` commit on
  `feat/issue-145-battery-not-run` (see the PR).

## Next step

Review by Jorge el Curioso, then human merge.
