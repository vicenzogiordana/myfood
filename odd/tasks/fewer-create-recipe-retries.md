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

- [x] T1 Optional blank string arguments are absent (route: inline, one module `tools.ex` + tests)
- [x] T2 Auto-resolve a clear single candidate in `create_recipe` (route: inline, `ingredient_match.ex`, `recipe_draft.ex`, `tools.ex` + tests)
- [x] T3 `sold_in` + hint on `no_matching_presentation` (route: inline, `purchase.ex` + tests)
- [x] T4 Tool descriptions, agent instructions, CHANNELS.md and CONTEXT.md updated

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

- T1: commit 22498a3; RED observed (2 failing), GREEN `mix test test/meal_planner_api/planning_agent/` 598 passed.
- T2: commit 45a3261; RED observed (resolve test failing without lib change), GREEN planning_agent suite 601 passed. Lead margin 0.2 chosen from probed scores: "Tomate"/"Tomate perita" 1.0 vs "Tomate cherry" 1.0 (ambiguous), "Queso mozzarella"/"Muzzarella" 0.41 alone (clear), "harina 000" two flours at 0.64 (ambiguous).
- T3: commit de4476b; RED observed (sold_in nil), GREEN planning_agent suite 603 passed.
- T4: create_recipe and replaces_recipe_id descriptions, Draft outcome note, Requested dishes instruction (T2) and CHANNELS.md updated across T2-T4 commits; CONTEXT.md needed no change (Ingredient entry already covers similarity matching).
- Not done (optional per issue, "where useful"): sold_in on unknown_ingredients.
- Known flaky, unrelated: SessionBoundsTest "backoff between retries increases" measured 59 ms vs 60 ms once (millisecond timing); passes on rerun.
