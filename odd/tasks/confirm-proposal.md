# Feature: Confirm Proposal (#102)

> **Issue**: #102 (spec #93, user stories 71–77, 88, 90–93)
> **Branch**: `feat/issue-102-confirm-proposal`
> **Baseline**: 139 planning agent tests passing on `main` (35db229)
> **Engram mirror**: `odd/confirm-proposal/tasks`

## Objective

Only a Member's click saves a plan. Confirming the exact displayed Proposal
revalidates it, saves its Planned Meals and appends its Purchase lines to the
Shopping List, idempotently by confirmation identity.

## Problem / why

The agent flow can present Proposals but nothing saves them. The legacy
confirm rebuilds the cart (deleting pending and in-cart lines) and is not
idempotent beyond the in-memory generation server.

## Scope

- `Session.confirm/4` (human action) and `Session.confirmation_status/2`
- `PlanningAgent.Proposal`: one Proposal builder shared by `present_proposal`
  and the confirm revalidation
- `PlanningAgent.Confirmation`: the confirmation store (one transaction:
  session committed, confirmation row, Planned Meals, appended Shopping List
  lines) with reconciliation of a lost acknowledgement
- Migration `planning_agent_confirmations` (identity = Proposal id)

Out of scope: Deviation Approval (#103; a `requires_approval` Proposal is
refused with `:approval_required` until then), AI recipe saving (#104),
grace/restart recovery (#107).

## Constraints

- No agent tool persists anything; confirm is not a tool.
- Existing pending and in-cart Shopping List lines are never touched.
- An unverifiable confirmation is `unresolved`, never `failed`.

## Acceptance criteria

- [x] Confirming the exact current Proposal saves Planned Meals and appends Purchase lines
- [x] Existing pending and in-cart Shopping List lines are untouched
- [x] A stale Proposal is not saved and the Member is asked again
- [x] A revalidation conflict blocks saving and leads to a corrected Proposal needing new approval
- [x] Replaying the same confirmation never saves twice
- [x] An unverifiable confirmation is reported as unresolved after 30 s, never as failed
- [x] No agent tool can persist a plan

## Tasks

- [x] **T1** Confirm saves the exact current Proposal (route: inline, single writer; tests through `Session`)
  - Proposal builder extracted from `Tools`; confirmation store + migration
  - Planned Meals saved, Purchase lines appended as pending lines, existing lines untouched
  - Session ends committed; slot released; no tool persists
- [x] **T2** Stale Proposals and revalidation conflicts (route: inline)
  - Wrong identity → `:stale_proposal`, nothing saved, current Proposal re-shown
  - Changed Projected Pantry / prices / budget → recalculated Proposal (new identity)
  - Restriction conflict → nothing saved, Proposal voided, agent turn corrects it
  - `requires_approval` → `:approval_required` until #103
- [x] **T3** Idempotency and lost acknowledgement (route: inline)
  - Replay (live session or after it ended) returns the original confirmation
  - Lost acknowledgement reconciled by status for up to 30 s, then `:unresolved`
  - Status stays queryable

## Checks

- `MIX_TEST_PARTITION=102 MYFOOD_TEST_DATABASE=meal_planner_api_test102 mix test`
- `mix precommit`

## Progress / evidence

| Task | Commit | Tests |
|------|--------|-------|
| T1   | b58251a | RED 3/5 (confirm/3 undefined; 2 no-persist characterization tests already green); GREEN 5/5; planning_agent suite 144 passed |
| T2   | 5cb59bb | RED 6/9 (stale/budget/conflict); GREEN 9/9; planning_agent suite 148 passed |
| T3   | this commit | No true RED: reconciliation and replay were written with T1; mutation check (disable reconcile + replay) failed 4/15, restored GREEN 15/15; `mix precommit` 1117 passed, 25 skipped |

## Next step

Open the PR; Deviation Approval (#103) lifts `:approval_required`.
