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

Out of scope: `meal_planner_api/ARCHITECTURE.md` is outside this task's edit
surface (follow-up if it still names legacy modules).

## Checklist

- [ ] T1 Haiku default for the Claude adapter (tests, docs).
- [ ] T2 Exhausted guard on revalidation-conflict turns.
- [ ] T3 Draft revision voids the shown Proposal.
- [ ] T4 Failure notice on the deadline path.
- [ ] T5 Merged-line cap and case-only variants.
- [ ] T6 Remove PythonClient, its Mock and stale config.
- [ ] T7 Drop legacy tables, schemas and PlanningRepo functions.
- [ ] T8 Stale docs and legacy root files.
- [ ] T9 Flaky test root cause.

## Acceptance criteria

- No doc or config presents the legacy planner as current.
- No dead modules remain from the legacy planner.
- The legacy tables are dropped through a migration.
- Each Jorge follow-up has a test through a public interface.
- `mix precommit` passes.

## Checks

- Focused `mix test <file>` per task (RED then GREEN).
- `MYFOOD_TEST_DATABASE=meal_planner_api_test151 mix test` (full suite).
- `mix precommit`.

## Progress

Baseline at origin/main 6590112: 1408 passed, 24 skipped.
