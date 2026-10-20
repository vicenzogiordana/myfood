# Planning agent: resolve conflicts, never dodge an infeasible budget (#148)

Part of spec #93. Source evidence: quality battery run 2 (2026-10-19), tasks
A1, A5, A6 and A10.

## Objective

Apply the owner's product decisions of 2026-10-19 to the planning agent:

1. Infeasible budget: say it cannot be done, name the real cause, and ask
   before creating new recipes. Never create Recipe Drafts on its own to
   escape the budget (A5).
2. Conflicting request (pinned recipe vs Restriction, pantry stock already
   committed): resolve and inform. Pick the safe or reasonable alternative,
   present the Proposal, explain what changed and why; do not ask first
   (A1, A6).
3. Single-meal change: release only that meal, re-optimize and present a
   replaced Proposal whose meal differs (A10).

## Why

- A5: 4/5 runs drafted saffron-free recipes silently and presented a valid plan.
- A1, A6: 0/5; the agent asked a question instead of proposing.
- A10: 2/5. Root cause found in code: every meal of the first plan used a
  recipe twice, so the agent's `run_optimizer(exclude_recipe_ids: [tuesday
  dinner])` also excluded that recipe from a kept meal and the optimizer
  answered `infeasible` (excluded fixed meal); retries hit the iteration
  limit. Without an exclusion the optimizer could keep the same recipe.

## Scope

- `optimizador.py`: optional `avoided_meals` (a recipe a free meal must not take).
- Workspace / `run_optimizer`: a meal released with `release` must change;
  per-run exclusions never break a kept meal.
- `create_recipe`: code-level refusal of AI-created Drafts while an
  unanswered budget Deviation stands in this turn; `present_proposal` returns
  the budget cause and guidance to relay.
- Agent instructions and the Restriction-Pin refusal reason: resolve and inform.
- Battery fixtures A1, A5, A6, A10 checked against the decisions.

Out of scope: running the paid battery (the parent re-runs it after merge).

## Constraints

- No real model-provider call in tests (Scripted model, FakeOptimizer).
- Code guards over prompt wording where cheap and deterministic.

## Tasks

- [x] T1 Released Meals change and per-run exclusions keep fixed meals (A10)
  - Route: inline (focused files already mapped: optimizador.py, tools.ex, workspace.ex)
  - RED: AvoidedMealTests (4 failing) and session_workspace_test "single-meal change" (4 failing)
  - Checks: `python -m unittest test_optimizador` (59 OK); `mix test test/meal_planner_api/planning_agent` (475 passed)
  - Commit: fdc1ae3
- [x] T2 Infeasible budget: create_recipe refuses AI Drafts after an unanswered budget Deviation; present_proposal returns the cause (A5)
  - Route: inline (tools.ex, workspace.ex, session.ex one line each area)
  - RED: budget_conflict_test (2 failing)
  - Checks: `mix test test/meal_planner_api/planning_agent` (479 passed)
  - Commit: 4e7088c
- [x] T3 Resolve and inform: instructions and Restriction-Pin refusal (A1, A6)
  - Route: inline
  - RED: household_context_test "conflicts" (4 failing), Restriction-Pin reason (1 failing)
  - Checks: household_context, session_workspace, purchase_tools tests passed
  - Commit: 062ffbb
- [x] T4 Battery fixtures and graders reviewed for A1, A5, A6, A10; docs
  - Route: inline
  - A1, A5, A6 fixtures already encode the decisions (solvable A1/A6 need a valid Proposal; A5 unsolvable, a valid Proposal is a hard violation). A10 grader now also requires every other meal kept; good A10 script releases only Tuesday dinner.
  - RED: grader_test "only the meal ... may change" (1 failing)
  - Checks: `mix precommit` (1477/1478; the one failure is the timing-based SessionBoundsTest backoff test, untouched, passes 4/4 in isolation)
  - Commit: see git log (docs(planning-agent) / test commit of T4)

## Acceptance criteria

- Infeasible budget: abstains with the real cause and offers recipe creation
  as a question; no Recipe Draft without an explicit user request (tool-level test).
- Pinned recipe vs Restriction and committed pantry: a valid Proposal with
  the substitution explained, without asking first (scripted tests).
- Single-meal change produces a replaced Proposal with only that meal changed.
- Battery fixtures A1, A5, A6, A10 still encode these expectations.
- No real model-provider calls in tests.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test148 mix test`
- `mix precommit`
- `python -m unittest test_optimizador` (venv outside the repo)

## Delivery

Strategy: single-pr (forecast about 400 authored lines). Native review is
run separately by the pipeline (Jorge el Curioso).

## Progress

- T1-T4 done.

## Next step

Open the PR; the parent re-runs the paid battery after merge.
