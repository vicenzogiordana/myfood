# Drafts stay on their meal, staples, formatted optimizer deviations (issue #162)

Part of spec #93. Locator: `odd/tasks/drafts-stay-on-meal-and-staples.md`.
Engram mirror: `odd/drafts-stay-on-meal-and-staples/tasks`.

## Objective

Fix four findings of a live Haiku 5.5 trial and two Jorge follow-ups on #161:
staples blocked a pizza, a requested-meal Draft spread to other days, optimizer
deviation amounts had no formatted twin, and the Port lacked optimizer error
codes.

## Scope (settled in the issue body)

- Staples (water, salt, pepper) never block `create_recipe`, are never
  purchased, priced or counted in cost, and need no catalog entry.
- A Draft pinned to a meal is a candidate only for its own meals. It becomes a
  candidate elsewhere only after the household asks (edit_workspace
  `repeat_recipe`, or pinning it to more meals). Revisions keep this.
- `run_optimizer` budget deviations carry `*_cents` fields, so `Money.annotate`
  adds formatted amounts.
- The Port maps every validation error code of `optimizador.py`,
  `invalid_skipped_meals` included.

## Tasks

- [x] T1 Port maps every optimizer error code (TR-1); the test reads the codes from optimizador.py. RED 7 failing, GREEN port_test 33/33. Commit 367a04a.
- [x] T2 Optimizer budget deviations carry `*_cents` and formatted amounts (CD-1). RED 1 failing, GREEN session_workspace_test 18/18. Commit c427eec.
- [x] T3 Staples in `create_recipe` (kept under `staples`, never priced or bought). RED 2 failing (+1 Purchase), GREEN recipe tests 33/33. Commit 6143ff0.
- [x] T4 Pinned Drafts stay on their meals (avoided elsewhere, not a free candidate); `repeat_recipe` opt-in. RED 4 failing, GREEN recipe_draft_confirm_test 15/15. Commit 5628732.
- [x] T5 Instructions, tool descriptions, CONTEXT.md and CHANNELS.md, committed with T3 and T4.

Route: single bounded worker, inline per task (the worker is the delegated
writer of this pipeline). No optimizer contract change: the Draft rule uses the
existing `avoided_meals` contract.

## Acceptance criteria

- `create_recipe` with water and salt but no catalog entries succeeds; they are
  not in the Purchase or cost.
- A Draft created and pinned for one meal is not chosen by `run_optimizer` for
  other meals, even when it is the cheapest candidate; after the opt-in it can be.
- `run_optimizer` budget deviations carry formatted amounts.
- The Port maps `invalid_skipped_meals`.
- Instructions and docs updated; `mix precommit` passes.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test162 mix test`
- `mix precommit`

## Progress

- Full suite `MYFOOD_TEST_DATABASE=meal_planner_api_test162 mix test`: 1395 passed, 24 skipped.
- `mix precommit`: exit 0, 1395 passed.
- `python -m unittest test_optimizador`: 64 OK (contract unchanged).

Next step: PR review (Jorge), then merge.
