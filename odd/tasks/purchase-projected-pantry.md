# Purchase and Projected Pantry (issue #100, spec #93)

## Objective

Check the grocery budget against what the Household must actually buy. The
agent sees the Projected Pantry (`get_pantry`), reads stored Price
Observations (`lookup_prices`), and `present_proposal` always carries one
deterministic Purchase: the Proposal's needs minus the Projected Pantry,
rounded up to whole store packages, priced with provenance, with the
consumed-ingredient cost reported separately.

## Problem / why

The tracer bullet (#96) presents Proposals without any spend check. The
legacy flow compares the budget against consumed-ingredient cost and
computes un-rounded net shortages, so a 1 kg bag used for 100 g is never
counted, and stock committed to other pending meals can be allocated twice.

## Scope

- Product and Price Observation storage (no live scraper; that is #101).
- Projected Pantry: usable Pantry lots minus stock committed to every
  not-yet-cooked Planned Meal from today on, inside or outside the range.
- Purchase calculation: aggregate needs once per ingredient and unit,
  subtract the Projected Pantry, round up to whole packages of the cheapest
  stored Product, price lines with product, presentation, supermarket,
  currency and observation date.
- `present_proposal`: always includes the Purchase; overspend becomes a
  budget Deviation (`requires_approval`); consumed cost reported separately;
  missing prices flagged as uncertainty, never zero.
- Out of scope: confirmation and Shopping List append (#102), live prices,
  freshness and brands (#101), unit conversion between recipe and product
  units (a mismatch is reported as a missing price).

## Constraints

- Prices are never invented or replaced by zero.
- The legacy net-shortage path stays untouched (legacy flow is switched off
  by #110); the agent flow uses the Purchase only.
- Tests through public interfaces (Session + scripted model, public module
  functions) with fictitious fixtures.

## Tasks

- [x] T1 Product + Price Observation storage and `lookup_prices` tool
  (route: inline, bounded worker is the single writer). Commit: ee6abec.
  RED observed (4/4 failing, `unknown_tool`), GREEN 4/4.
- [x] T2 Projected Pantry module and `get_pantry` tool (route: inline).
  Commit: e6e3415. RED observed (2 failing), GREEN 6/6.
- [x] T3 Purchase calculation and `present_proposal` budget comparison,
  consumed cost, uncertainty; agent instructions and docs (route: inline).
  RED observed (7 failing), GREEN 14/14. Commit: the
  `feat(planning-agent): price Proposals with a package-rounded Purchase`
  work unit on this branch.

## Acceptance criteria

- [x] Projected Pantry subtracts stock committed to pending Planned Meals,
  including outside the new range
- [x] Purchase lines are rounded to whole packages and each purchase is
  counted once
- [x] Budget comparison uses the Purchase total; consumed cost is reported
  separately
- [x] Missing prices are flagged as uncertainty and never replaced by zero or
  invented values
- [x] Every price line carries product, presentation, supermarket, currency
  and observation date

## Checks

- `MIX_TEST_PARTITION=100 MYFOOD_TEST_DATABASE=meal_planner_api_test100 mix test`
- `mix precommit`

Note: `config/test.exs` does not append `MIX_TEST_PARTITION` to the database
name; isolation uses `MYFOOD_TEST_DATABASE`.

## Progress / evidence

- Decisions: a zero household budget means "not set" (no budget Deviation);
  budget currency is ARS; uncooked Planned Meals before today do not commit
  stock; recipe/product unit mismatch is a missing price
  (`no_matching_presentation`), no conversion yet; with missing prices
  `within_budget` is unknown unless the lower bound already overspends.
- The legacy `ShoppingRebuilder` path is untouched; the agent flow uses
  `PlanningAgent.Purchase`. Confirmation appending Purchase lines is #102.
- Full-suite and precommit results are recorded in the PR body.
