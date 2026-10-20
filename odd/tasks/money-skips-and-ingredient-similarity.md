# Formatted money, skipped meals and similarity ingredient matching (issue #160)

Part of spec #93. Locator: `odd/tasks/money-skips-and-ingredient-similarity.md`.
Engram mirror: `odd/money-skips-and-ingredient-similarity/tasks`.

## Objective

Fix three problems found in a live Haiku 5.5 terminal-chat trial: the model
read integer cents as pesos (100x too high), a meal could not be left
unplanned ("we won't eat at home Wednesday night"), and ingredient matching
was too literal ("no mozzarella" while the catalog has "Muzzarella").

## Scope (settled in the issue body)

- Every model-facing tool result carrying money also carries a code-formatted
  amount (`"ARS 49.950,00"`) next to the `*_cents` integer; the instructions
  tell the model to quote only formatted amounts and never compute from cents.
- `edit_workspace` `skip` / `unskip` a day and slot for the whole Household:
  not planned, not in the Purchase or consumed cost, not saved on
  confirmation, shown as skipped in the Proposal, excluded from the optimizer
  range. Distinct from Absence Exceptions. Applied without asking.
- Ingredient names resolve through `pg_trgm` + `unaccent` similarity
  (migration with the extensions and a trigram GIN index) in `create_recipe`
  close matches and every ingredient lookup the tools expose
  (`lookup_prices`, `set_session_brand`, `search_recipes`). Ranked by
  similarity above a threshold; empty matches keep the #158 behavior.
  An unambiguous spelling variant (case, accents, a plural ending) resolves
  automatically and the model is told which catalog name was used.

## Tasks

- [ ] T1 Similarity matching: migration (extensions, immutable search key,
      GIN trigram index) and `IngredientMatch`; `create_recipe` close matches
      ranked by similarity, unambiguous variants auto-resolved.
- [ ] T2 Similarity in `lookup_prices`, `set_session_brand` and the
      `search_recipes` ingredient filter.
- [ ] T3 Code-formatted money in every model-facing tool result and the
      budget line of the instructions; instructions say to quote it.
- [ ] T4 Skipped meals: Workspace `skip`/`unskip`, optimizer payload
      `skipped_meals` (Elixir + `optimizador.py`), validator, Proposal
      `skipped`, Purchase and confirmation exclude them.
- [ ] T5 Docs: CHANNELS.md, OPTIMIZER_CONTRACT.md, CONTEXT.md glossary.

Route: single bounded worker, inline per task (this worker is the delegated
writer of the pipeline; it must not spawn subagents).

## Acceptance criteria

- Tool results carry formatted money alongside cents; a test shows the
  instructions tell the model to quote formatted amounts.
- Skip a slot: the optimizer does not fill it, the Purchase excludes it, the
  Proposal shows it skipped, confirmation saves nothing for it; unskip
  restores it.
- Trigram matching finds "Muzzarella" for "mozzarella", "Harina de trigo" for
  "harina", accent and plural variants; unrelated names stay below the
  threshold.
- The migration runs in test and dev; docs updated; `mix precommit` passes;
  optimizer tests pass.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test160 mix test`
- `mix precommit`
- `python -m pytest test_optimizador.py` (venv outside the repo)

## Progress

(updated per task)
