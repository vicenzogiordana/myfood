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

- [x] T1 Similarity matching: migration (extensions, immutable search key,
      GIN trigram index) and `IngredientMatch`; `create_recipe` close matches
      ranked by similarity, unambiguous variants auto-resolved. RED 6/6
      failing (ingredient_match_test), GREEN 27/27. Commit 22f3be0.
- [x] T2 Similarity in `lookup_prices`, `set_session_brand` and the
      `search_recipes` ingredient filter. RED 5 failing with lib stashed,
      GREEN 79/79. Commit 1fe44de.
- [x] T3 Code-formatted money in every model-facing tool result and the
      budget line of the instructions; instructions say to quote it. RED 5
      failing, GREEN planning_agent suite 556/556. Commit 22e73ed.
- [x] T4 Skipped meals: Workspace `skip`/`unskip`, optimizer payload
      `skipped_meals` (Elixir + `optimizador.py`), validator, Proposal
      `skipped`, Purchase and confirmation exclude them. RED Python 9
      failing / Elixir 5/5 failing; GREEN Python 63/63, Elixir 6/6.
      Commit 3bfd8a5.
- [x] T5 Docs: CHANNELS.md, OPTIMIZER_CONTRACT.md, CONTEXT.md glossary
      (in commit 3bfd8a5). Passive docs: structural readback.

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

All tasks done. Full suite `mix test` (MYFOOD_TEST_DATABASE=meal_planner_api_test160):
1362 passed, 24 skipped. `mix precommit` clean. Optimizer: 63 tests OK.
Migration ran on test and dev databases.

Decision: auto-resolution only for case, accent, punctuation and plural
variants. Trigram similarity alone is unsafe to auto-resolve ("queso crema"
vs "Queso cremoso" scores 0.67), so merely similar names stay close matches.

Next step: review gate (Jorge el Curioso), then merge.
