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

- [ ] T1 Port maps every optimizer validation code (TR-1).
- [ ] T2 Optimizer budget deviations carry formatted amounts (CD-1).
- [ ] T3 Staples in `create_recipe`.
- [ ] T4 Pinned Drafts stay on their meals; `repeat_recipe` opt-in.
- [ ] T5 Instructions, tool descriptions, CONTEXT.md and docs.

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
