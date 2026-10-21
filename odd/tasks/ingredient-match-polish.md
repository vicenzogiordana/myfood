# Ingredient matching polish (issue #166, part of #93)

## Objective

Address the minor follow-ups from Jorge's review of PR #165 (issue #164):
an actionable `duplicate_ingredient`, docs in code and in `docs/` that match
the implementation, a restored ranked-order assertion, `sold_in` limited to
the household currency, and a clear-match decision that floating-point noise
cannot flip.

## Scope (settled in #166)

1. Two different requested names that resolve to one Ingredient: merge their
   quantities when the units match and report the merge; otherwise return a
   `duplicate_ingredient` error naming the requested names and the Ingredient.
2. `ingredient_match.ex` moduledoc and `@retry_hint` match `clear_matches/1`.
3. Docs match the diff: the `lookup_prices` / `sold_in` claim and the
   CONTEXT.md note of the #164 feature document.
4. One test asserts the ranked order of `close_matches`.
5. `sold_in` lists only units of offers in the household currency; the
   Proposal `missing_prices` hint is informational, not a retry instruction.
6. The similarity lead is rounded before it is compared with `@clear_lead`;
   a boundary test covers a lead of exactly 0.2.

## Checklist

- [x] T1 Merge or reject requested names resolving to one Ingredient (route: inline, `recipe_draft.ex`, `tools.ex`, CHANNELS.md + recipe_tools test)
- [x] T2 Rounded clear lead, boundary and ranked-order tests, moduledoc and `@retry_hint` (route: inline, `ingredient_match.ex`, `recipe_draft.ex` + tests)
- [ ] T3 `sold_in` in the household currency, informational Proposal hint, docs reconciled (route: inline, `purchase.ex`, CHANNELS.md, #164 feature doc + tests)

Route note: the parent delegated this whole issue to one bounded worker; the
worker is not an orchestrator, so every task runs inline in that worker.

## Acceptance criteria

- A test covers each item where it applies.
- `mix precommit` passes.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test166 mix test`
- `MYFOOD_TEST_DATABASE=meal_planner_api_test166 mix precommit`

## Progress / evidence

- T1: commit c0bcc19; RED observed (both new recipe_tools tests failing: the
  merge case drafted two lines, the unit-conflict case drafted instead of
  erroring), GREEN planning_agent suite 605 passed. Settled reading: one name
  listed in two units stays two lines (the catalog allows one Ingredient per
  unit); only different requested names colliding on one Ingredient merge or
  fail.
- T2: commit (this one); RED observed for the boundary test ("pera": Pera 1.0
  vs Peras 0.8 subtracts to 0.19999998, so clear_matches left it out); the
  ranked-order test ("queso cremos": Queso cremoso 0.92 before Queso crema
  0.77, not alphabetical) restores the ordered assertion and passed as
  written. GREEN planning_agent suite 607 passed. `@retry_hint` no longer
  cites mozzarella/Muzzarella (now a clear match) and says the remaining
  candidates score alike.
