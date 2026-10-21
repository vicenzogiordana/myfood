# Clean up legacy planner leftovers (#151)

Branch: `feat/issue-151-legacy-cleanup`. Parent spec: #93.

## Objective

Remove what the retired legacy planner left behind (stale docs and config,
dead modules, legacy tables, legacy root files), close the accumulated Jorge
follow-ups from #155, #157 and #167, fix the intermittent test, and make
Claude Haiku 5.5 the Claude adapter's default model (user request on
2026-10-21: "dejes por defecto a haiku, porque ahora está opus").

## Scope

- Docs and config that present the legacy planner as current.
- `Integrations.PythonClient` and its Mock.
- `planning_proposals` and `planning_generation_runs`: dropped through a
  migration with their schemas and PlanningRepo functions.
- Legacy root files: `generador.py`, `move_proposal.patch`,
  `patch_planning.sh`, `patch_script.sh`, `.pi/`.
- Draft revision voids the shown Proposal that uses it (Jorge C2 on #155).
- Exhausted guard on revalidation-conflict turns (Jorge TR-1 on #155).
- Failure notice on the Session wall-clock deadline path (Jorge TR-1 on #157).
- Merged-line quantity cap and case-only name variants (Jorge CD-1/CD-2 on #167).
- The intermittent test.
- Claude adapter default: `claude-haiku-5-5`, with refusal fallbacks off
  (Haiku 5.5 rejects the `fallbacks` parameter, #156).

Out of scope: `meal_planner_api/ARCHITECTURE.md` (outside this task's edit
surface) still names `MealPlannerApi.Planning`, `PlanningChat` and
`PythonOptimizerClient`; `meal_planner_api/openspec/changes/**` are change
history. Both are follow-ups.

## Checklist

Route for every task: inline in this bounded worker (no subagents by the
pipeline contract); the work was mapped with bounded searches first.

- [x] T1 Haiku default for the Claude adapter (tests, docs). `411bcc0`.
  RED: 3 failures (default model, fallbacks default, runtime default). GREEN:
  model, runtime config and battery tests 172 passed.
- [x] T2 Exhausted guard on revalidation-conflict turns. `6fd1933`.
  RED: a turn started after the conflict. GREEN: the session emits
  `session_budget_exhausted` (proposal null) and ends; no model request.
- [x] T3 Draft revision voids the shown Proposal. `b865ec1`.
  RED: no `proposal_invalidated`. GREEN: `recipe_draft_revised`, confirm of
  the old Proposal is `stale_proposal`, nothing saved.
- [x] T4 Failure notice on the deadline path. `ba6ce1d`.
  RED: no notice before `limit_reached "time"`. GREEN: the Loop reports the
  notice after each tool call; the Session shows it when its deadline kills
  the turn.
- [x] T5 Merged-line cap and case-only variants. `8024a3e`.
  RED: 3 failures. GREEN: `quantity_too_large`, names deduped by case.
- [x] T6 Remove PythonClient, its Mock and stale config. `6b8ca29`.
  Dev optimizer keys moved out of the Endpoint config, where nothing read them.
- [x] T7 Legacy tables: closed once by a data migration, schemas and
  PlanningRepo functions removed. `001c9b4`, plus the dead
  `PlanningCandidateBuilder` and its repo functions in `f7cd253`.
  Dropping the tables was attempted and blocked by the session's permission
  classifier (destructive data change); the issue allows the cleanup path.
- [x] T8 Stale docs and legacy root files. `d9ff43f`.
- [x] T9 Flaky tests. `b785215`, `2cc91f1`. 12 full runs on main: 2
  failures, both no-progress runs (`session_bounds_test.exs:534` and
  `planning_agent_channel_test.exs:280`); a third timing failure (backoff
  test) was seen while iterating. Causes: real DB searches under a 100 ms
  read deadline, the default 100 ms `assert_push` for a multi-step run, and
  backoff measured at message receipt instead of call time.

## Acceptance criteria

- No doc or config presents the legacy planner as current.
- No dead modules remain from the legacy planner.
- The legacy tables are cleaned up through a migration (issue option one).
- Each Jorge follow-up has a test through a public interface.
- `mix precommit` passes.

## Checks

- Focused `mix test <file>` per task (RED then GREEN).
- `MYFOOD_TEST_DATABASE=meal_planner_api_test151 mix test` (full suite).
- `mix precommit`.

## Progress

Baseline at origin/main 6590112: 1408 passed, 24 skipped.
`mix precommit` at `d9ff43f`: passed, 1411 passed, 24 skipped.
Full suite 10 times in a row at `d9ff43f`: 10/10 runs 1411 passed, 24 skipped.

## Next step

Push, open the PR, Jorge el Curioso review. Decide separately whether to
drop the legacy tables (now closed and unread).
