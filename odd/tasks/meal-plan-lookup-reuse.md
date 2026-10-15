# Meal Plan lookup and reuse (#105)

Part of spec #93. Branch `feat/issue-105-meal-plan-lookup-reuse`.

## Objective

The planning agent can read the Household Meal Plan with `get_plan` (by date
or range, planned, not eaten) and reuse a past stretch ("repeat the week
before last") as a fresh draft that must pass full validation before it is
shown.

## Problem / why

Members want to look back at what was planned and repeat it. Reuse must never
bypass current rules: Restrictions, availability, dates and portions are
revalidated, and past Deviation Approvals and Absence Exceptions are never
inherited.

## Scope

- `get_plan` tool: Planned Meals of the session's Household only, for one date
  or an inclusive range (bounded), ordered by date and slot. Household always
  from the session; model arguments naming a Household are ignored.
- `reuse_plan` tool: copies the Planned Meals of a past window starting at
  `source_from` onto the Planning Range day by day (same offset), for the
  session's slots only, into the workspace draft. The draft holds only date,
  slot and recipe; portions, recipe versions, approvals and exceptions are
  not copied. `present_proposal` then runs the full validator.
- Out of scope: Projected Pantry and prices (#100, #101) join the validator in
  their own slices; reuse inherits them automatically since it goes through
  `present_proposal`.

## Constraints

- No tool writes persistent data.
- Tests through the session interface with the scripted model and fictitious
  fixtures; DB partition `MIX_TEST_PARTITION=105` (test DB name comes from
  `MYFOOD_TEST_DATABASE`, so it is set explicitly per run).

## Tasks

| ID | Task | Route | Status |
|----|------|-------|--------|
| T1 | `get_plan` tool + tests (date, range, household isolation, invalid input) | inline (2 files: tool + test) | pending |
| T2 | `reuse_plan` tool + tests (fresh valid Proposal, current Restriction revalidation, no inherited approvals/exceptions, slots/dates mapped) | inline | pending |

- [ ] T1 get_plan
- [ ] T2 reuse_plan

## Acceptance criteria

- [ ] get_plan returns Planned Meals for a date or range of the session's Household only
- [ ] Reusing a past week produces a fresh Proposal that passes full validation
- [ ] No past approval or exception carries over

## Checks

- `MIX_TEST_PARTITION=105 mix test`
- `mix precommit`

## Progress

- Baseline: `mix test test/meal_planner_api/planning_agent` 59 passed.
