# Planning session limits and Recipe Draft fixes (issue #154)

Part of spec #93. Locator: `odd/tasks/session-limits-and-draft-fixes.md`.
Engram mirror: `odd/session-limits-and-draft-fixes/tasks`.

## Objective

A live trial broke after three turns with US$0.15 of a US$3 cap spent. Make
the money cap the real limit, keep the user from ever being stranded when a
limit is exhausted, and fix the Recipe Draft dead ends (pinning, duplicates,
ingredient discovery).

## Scope (settled in the issue body)

- Money cap (`PLANNING_AGENT_SPEND_CAP_MICROS`) is the real limit; the money
  reservation stays conservative.
- Token cap is a safety net: realistic reservation (request bytes / 3, no
  fallback doubling), cache reads do not count toward it.
- Iterations: 15 model calls per Member message, 60 per Planning Session;
  calls refused before reaching the provider do not count.
- Exhausted cap or ceiling: `session_budget_exhausted` with a code-rendered
  message and the latest Proposal; no further refused turns.
- Recipe Drafts can be pinned (slot, Restrictions, plannability respected).
- Re-creating a Draft (`replaces_recipe_id`, or same name and origin) revises
  it instead of adding a duplicate.
- A Draft missing only nutrition or prices is usable: the model is told not to
  retry for that.
- `unknown_ingredients` lists close catalog matches.

## Tasks

- [x] T1 Pin Recipe Drafts (`Workspace` pin checks the Workspace's Drafts). Commit 1dbf6ec; RED 4 failing, GREEN recipe_draft_confirm_test 8/8.
- [x] T2 Revise a Draft instead of duplicating; partial Drafts are usable. RED 5 failing, GREEN recipe_tools_test 16/16 Commit 312202e..
- [x] T3 `unknown_ingredients` returns close catalog matches. RED 1 failing, GREEN recipe_tools_test 17/17. Commit bab1199.
- [ ] T4 Per-message iterations (15) with a session ceiling (60); refused
      calls are not counted.
- [x] T5 Realistic token reservation; cache reads excluded from the token cap.
      RED 3 failing (113,132 reserved vs 29,522 expected for a ~44 KB body);
      GREEN claude_messages_test 53/53, planning_agent suite green.
- [ ] T6 Exhausted cap ends the session gracefully with
      `session_budget_exhausted`; channel forwards it.
- [ ] T7 Docs (QUALITY_BATTERY, CHANNELS, agent docs, env vars).

Route: single bounded worker, inline per task (the worker is the delegated
writer of this pipeline).

## Acceptance criteria

- `create_recipe` -> `pin` (draft) -> `run_optimizer` -> `present_proposal`
  succeeds.
- Re-creating a Draft with `replaces_recipe_id`, or the same name and origin,
  leaves one Draft.
- `unknown_ingredients` lists close matches.
- Iterations reset per message (15) and stop at the session ceiling (60);
  refused calls do not count.
- The token reservation for a ~40 KB body is well below the old estimate;
  cache reads do not count toward the token cap.
- An exhausted cap ends the session with `session_budget_exhausted`, the
  latest Proposal and no further refused turns; the channel forwards it.
- Docs updated; `mix precommit` passes.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test154 mix test`
- `mix precommit`

## Progress

(updated per task with commit evidence)
