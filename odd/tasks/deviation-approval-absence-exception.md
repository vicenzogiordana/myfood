# Feature: Deviation Approval and Absence Exception (#103)

> **Issue**: #103 (spec #93, user stories 11, 17, 62, 65, 65a, 66, 67)
> **Branch**: `feat/issue-103-deviation-approval`
> **Baseline**: 155 planning agent tests passing on `main` (0ed8356)
> **Engram mirror**: `odd/deviation-approval-absence-exception/tasks`

## Objective

Members approve trade-offs explicitly, through human-only actions of the
planning agent session module that the agent can only ask for.

## Problem / why

A `requires_approval` Proposal (a budget Deviation) cannot be confirmed at
all today (`:approval_required` since #102), and a Restriction can never be
lifted for a Member who is away, even though the Restriction validator
already accepts Absence Exceptions as input.

## Scope

- `Session.approve_deviations/3`: one all-or-nothing Deviation Approval of
  the exact displayed Proposal; confirm accepts a `requires_approval`
  Proposal only with an approval for that exact Proposal identity
- Any change to the Proposal (a new Proposal from the agent, or a
  recalculated one at confirmation) voids the approval
- `Session.approve_absence_exception/3`: one Restriction of one Member,
  lifted for specific meals of the Planning Range; held in the Workspace,
  read by the validator in `present_proposal` and in confirm revalidation
- Approvals are human-owned Workspace fields: a turn result can never set
  or change them, and no tool grants them

Out of scope: recipe search and optimizer candidates honouring Absence
Exceptions (search is per slot, an exception is per meal; the validator is
the gate), flagging a meal for review when the absent Member later attends
(story 68), channel wiring (the channel does not wire confirm yet), the
OpenAI spend/token caps (already per Planning Session, unchanged here).

## Constraints

- Stored budget and Nutrition Goal never change on approval.
- An Absence Exception never edits a profile and is never inherited when
  meals are reused (it lives only in this session's Workspace).
- Violations and events stay generic: no Member or Restriction is named.

## Acceptance criteria

- [x] A Proposal requiring approval cannot be confirmed without a Deviation Approval for that exact Proposal
- [x] Changing the Proposal voids the approval
- [x] Stored budget and Nutrition Goal are unchanged after approving
- [x] An Absence Exception lets the validator accept exactly the approved meals
- [x] The agent has no tool to grant either approval

## Tasks

- [x] **T1** Deviation Approval (route: inline, single writer; tests through `Session`)
  - approve exact current `requires_approval` Proposal; confirm then saves
  - refusals: forbidden, busy, stale, no deviations, no session
  - void on a new or recalculated Proposal
  - budget and Nutrition Goal unchanged
- [x] **T2** Absence Exception (route: inline)
  - validation of member, Restriction and meals
  - validator accepts exactly the approved meals (tag and exact-ingredient allergies)
  - revalidated at confirm; not inherited by reuse
- [x] **T3** Human-only guarantee (route: inline)
  - no tool grants either approval; a turn result cannot set them
  - instructions tell the agent it can only ask

## Checks

- `MIX_TEST_PARTITION=103 MYFOOD_TEST_DATABASE=meal_planner_api_test103 mix test`
- `mix precommit`

## Progress / evidence

| Task | Commit | Tests |
|------|--------|-------|
| T1   | feaa930 | RED 0/5 (approve_deviations/3 undefined); GREEN 5/5; planning_agent suite 160 passed |
| T2   | f5e8e21 | RED 5/10 (approve_absence_exception/3 undefined); GREEN 10/10; planning + planning_agent suites 185 passed |
| T3   | (this commit) | No true RED: characterization tests (no approval tool exists; an agent calling one gets unknown_tool and confirm stays approval_required), green 12/12; planning_agent suite 167 passed x3; `mix precommit` first run 1127/1130 (3 failures not reproduced, not captured), then 1130 passed, 25 skipped twice |

Note: `config/test.exs` does not append `MIX_TEST_PARTITION` to the DB name;
isolation uses `MYFOOD_TEST_DATABASE=meal_planner_api_test103`.

## Next step

Open the PR; review by Jorge el Curioso.
