# Quality battery gate (issue #109, spec #93)

## Objective

Build the pre-launch quality battery agreed in #87: 15 tasks (4 routine,
11 adversarial) run 5 times each through the planning agent session module,
with fictitious offline fixtures (identical prepared recipe and price
responses), producing a pass/fail report with per-run evidence.

## Problem / why

Spec #93 ships the agent only after the battery passes (user story 107) and
switches the legacy planner off only afterwards (108). There was no battery,
no fixtures, no run command and no report format.

## Scope

In: battery configuration (spend ceiling and #87 deferred criteria, no
defaults, refusal without them), the 15 reproducible fixtures, the runner
(sandboxed per run, real session module, injectable model), the grader
(hard rules, abstention policy, 90% minimum), the report (JSON or Markdown),
the single run command and its docs. All of it tested offline with the
scripted model.

Out: running the battery against the real provider (a human runs it and
attaches the report to #109, which stays open), choosing the numeric
values of the spend ceiling and the deferred criteria.

## Constraints

- No paid call and no internet in this work; tests use the scripted model.
- The spend ceiling and deferred criteria have no default values.
- Fictitious fixtures only; tests through public interfaces.
- `MYFOOD_TEST_DATABASE=meal_planner_api_test109`.

## Delivery

The work was split into three chained PRs to main (strategy
`stacked-to-main`), one per task:

1. Slice 1/3 — T1: configuration, grader, report (merged, #138).
2. Slice 2/3 — T2: the 15 fixtures and the runner (this PR).
3. Slice 3/3 — T3: the `mix planning_agent.battery` command and its docs.

## Tasks

- [x] T1 Battery configuration and grading: config validation refusing without spend ceiling / deferred criteria; grader (hard rules, abstention, relevance, variety, recovery, harness failures); report aggregation and verdict (68/75 pooled gate); JSON and Markdown rendering (route: inline, pure modules + tests)
- [x] T2 The 15 fixtures and the runner: declarative tasks, kitchen builder, sandbox per run, session driver, prepared scraper/search, spend meter, spend ceiling stop (route: inline, single writer) — slice 2/3
- [ ] T3 One command: `mix planning_agent.battery`, docs (route: inline) — slice 3/3

Route evidence: this worker is a bounded single writer (no sub-delegation
by instruction), so every task is inline in this worker.

## Acceptance criteria (issue #109)

- All 15 tasks exist as reproducible fixtures (this slice)
- One command runs 15 x 5 runs and produces a pass/fail report with per-run evidence (runner and `Battery.run/2` in this slice; command in slice 3)
- Any hard-rule violation presented as valid fails the battery regardless of score (grader and report, slice 1; exercised end to end in this slice)
- The run refuses to start without a configured spend ceiling (configuration, slice 1; enforced by the runner in this slice)
- The report is attached to #109 when executed (human step, pending)

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test109 mix test`
- `MYFOOD_TEST_DATABASE=meal_planner_api_test109 mix precommit`

## Progress

- T1 originally commit 30f7bcc on `feat/issue-109-quality-battery`, landed
  here as slice 1/3 with the files at that branch's head (which adds the
  `{:uses_ingredient, ingredient}` relevance check). RED: `grader_test.exs`
  0/25 and `report_test.exs` 0/13 (modules undefined); GREEN: battery unit
  tests passed. The config tests were written right after `Config` (no RED
  observed). The test fixture `BatteryFixtures.config_map/0` comes with it.
- T2 originally commit 65b7592 on `feat/issue-109-quality-battery`, landed
  here as slice 2/3 with the files unchanged at that branch's head. Kitchen,
  15 tasks, runner, prepared scraper, failing search, metered model and
  `Battery.run/2`. Test-first exception: the end-to-end test was written
  after the modules; its teeth are the hard-violation, spend-ceiling and
  harness-failure cases, each failing the verdict. First GREEN attempt
  failed A10 (the released meal kept its recipe), fixed in the scripted
  agent by excluding the old recipe; `battery_test.exs` passes (15 x 5
  offline run, scripted model, no paid call).
- Decisions: the battery runs only where the Repo uses the SQL sandbox
  (`MIX_ENV=test`), every run is rolled back; per-run spend cap lowered to
  what is left of the ceiling; a gate without evidence does not pass.

## Pending

- T3 (slice 3/3).
- A human runs the battery against the real provider with a filled-in
  configuration and attaches the report to #109 (acceptance criterion 5).

## Next step

Land slice 3/3 (`mix planning_agent.battery` and docs).
