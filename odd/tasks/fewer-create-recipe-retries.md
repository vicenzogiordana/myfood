# Fewer create_recipe retries (issue #164, part of #93)

## Objective

Cut wasted `create_recipe` attempts seen in the Haiku 5.5 terminal-chat trial
(2026-10-21): empty optional arguments read as values, obvious single
catalog matches rejected, and unit mismatches the model cannot fix.

## Scope (settled in #164)

1. Empty or whitespace-only strings for optional tool arguments are absent,
   normalized once in the tool argument layer (`Tools.execute/3`), driven by
   each tool's JSON schema (optional = not in `required`).
2. `create_recipe` auto-resolves an unknown name with exactly one similarity
   candidate, or a top candidate clearly ahead of the rest (score lead of at
   least 0.2 over the next one), and reports `resolved`
   (`requested`/`used`). Ambiguous names still fail with ranked
   `close_matches`; empty matches keep #158 behaviour.
3. A `no_matching_presentation` missing price carries `sold_in` (the
   presentation units the catalog sells) and a hint to restate the quantity
   in that unit. Code never converts units.

## Checklist

- [ ] T1 Optional blank string arguments are absent (route: inline, one module `tools.ex` + tests)
- [ ] T2 Auto-resolve a clear single candidate in `create_recipe` (route: inline, `ingredient_match.ex`, `recipe_draft.ex`, `tools.ex` + tests)
- [ ] T3 `sold_in` + hint on `no_matching_presentation` (route: inline, `purchase.ex` + tests)
- [ ] T4 Tool descriptions, agent instructions, CHANNELS.md and CONTEXT.md updated

Route note: the parent delegated this whole issue to one bounded worker; the
worker is not an orchestrator, so every task runs inline in that worker.

## Acceptance criteria

- `replaces_recipe_id: ""` creates a new Draft; empty optional strings in
  other tools are absent.
- "Tomate" resolves to "Tomate perita", "Queso mozzarella" to "Muzzarella",
  with the substitution reported; two close candidates still return
  `unknown_ingredients`.
- An Ingredient given in `unit` but sold only in `g` returns
  `sold_in: ["g"]` with the hint.
- Tool descriptions and instructions updated; `mix precommit` passes.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test164 mix test`
- `mix precommit`

## Progress / evidence

Filled per task with commit identities.
