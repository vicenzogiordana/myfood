# Switch off the legacy planner (issue #110, part of spec #93)

Locator: `odd/tasks/switch-off-legacy-planner.md` (Engram mirror topic
`odd/switch-off-legacy-planner/tasks`).

## Objective

After the quality battery passed, Households plan only through the culinary
agent (`MealPlannerApi.PlanningAgent.Session`). The `planning:*` channel
serves the agent flow, and the legacy planning flow is retired.

## Problem / why

Two planners coexisted: the agent (spec #93) and the legacy flow (regex
intent parsing, the in-memory non-cancellable `Generation.Server`, and the
`OptimizerServer` that silently fell back to a greedy plan). The legacy flow
could still produce plans that bypass the agent's validator, bounds, consent
and human-only confirmation.

## Gate evidence (AC 1)

The passing battery report is linked on #109: run 3, 2026-10-19,
claude-opus-5-5, PASS 73/75 (score 0.9733, every gate passed). Full report:
https://gist.github.com/vicenzogiordana/af9cca51041d16642951f5a994fa4924.
#109 is closed.

## Scope

Retired (removed with their tests):

- Legacy `PlanningChannel` (`generate_menu`, `chat`, `swap_constraints`,
  `confirm_proposal`, `reject_proposal`, `start_planning`, `send_message`
  with typed intents, `cancel_planning`) and `IntentAtomizer`.
- `Generation.Server` + `Generation.Supervisor` (the in-memory,
  non-cancellable generation server) and the legacy
  `PlanningSessionServer` / `PlanningSessionSupervisor`.
- Regex intent parsing in `GenerationService` (`parse_modification` and its
  helpers) and the typed-intent forwarding from `AIChannel` into the legacy
  session.
- `OptimizerServer` with its silent greedy `OptimizerFallback`, and the REST
  plan-generation endpoints that used it (`GET /api/planning/weekly`,
  `POST /api/planning/confirm`, `POST /api/planning/chat`,
  `POST /api/planning/proposals/:id/reject`).

Kept: the DB-backed planning session lock (`PlanningRepo`,
`PlanningSession` and its sweeper), `PlanningCandidateBuilder`,
confirmed-plan persistence (`ScheduledMeal`, agent confirmation), the
Shopping List, `OptimizerPortRunner`, `Variety`, `Optimization.Contract`,
favorites endpoints, the AI chat stream.

Constraints: no migration and no data change; confirmed Meal Plans and
Shopping Lists stay as they are.

## Acceptance criteria

- [x] Only start after a passing battery report is linked (see Gate evidence).
- [ ] The planning channel serves the agent flow only.
- [ ] Regex intent parsing, the legacy generation server and the greedy
      fallback are removed with their tests.
- [ ] Existing confirmed Meal Plans and Shopping Lists are unaffected.

## Tasks

- [x] T1 — Route `planning:*` to the agent channel; delete the legacy
      `PlanningChannel`, `IntentAtomizer`, the AI chat intent forwarding, and
      the legacy session server/supervisor. Route: inline (single writer,
      deletion-dominated).
- [x] T2 — Delete `Generation.Server` / `Generation.Supervisor` and the regex
      intent parsing in `GenerationService`. Route: inline.
- [ ] T3 — Delete `OptimizerServer` + `OptimizerFallback` and the REST
      plan-generation endpoints and services that depended on them. Route:
      inline.
- [ ] T4 — Docs (ARCHITECTURE, socket docs) and full checks.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test110 mix test`
- `mix precommit`

## Progress / evidence

- T1 (`dd70187`): RED observed (`assert socket.channel == PlanningAgentChannel`
  failed against main's routing); GREEN: channel + generation tests 127 passed.
- T2 (commit "retire the legacy generation server and regex intent
  parsing"): RED observed on `legacy_planner_retired_test.exs` (4/8 passed);
  GREEN: services, optimization and web tests 537 passed after seeding plans
  in `planning_candidate_builder_test.exs` (it relied on another test's
  committed plans and failed alone on a fresh database).

## Delivery

Strategy: `single-pr`. The diff is dominated by file deletions; authored
additions stay small. Line count exceeds the 400-line heuristic because whole
legacy modules and their tests are deleted, which cannot be split without
leaving dead code behind.
