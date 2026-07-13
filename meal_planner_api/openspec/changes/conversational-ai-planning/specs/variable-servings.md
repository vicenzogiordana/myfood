# Variable Servings

## Purpose

Defines per-slot requested servings flowing end-to-end: `ScheduledMeal`,
`proposal_json` slot shape, the optimizer payload, `optimizador.py`'s
cost/macro scaling, shopping-item quantity scaling, and cooking-completion
inventory deduction — replacing today's implicit single-serving assumption
(`Recipe.servings` exists but is inert; `quantity_milli` is copied raw).

**Owner decisions referenced**: default servings = count of `:active`
`AccountMembership` rows for the account; shopping scaling = exact linear
multiplication, packaging-aware rounding out of scope.

## Requirements

### Requirement: ScheduledMeal carries a servings value

`ScheduledMeal` MUST persist a `servings` integer field, `> 0` and `<= 20`
(configurable cap), defaulting to `1` when omitted (preserving today's
implicit behavior on rollback). The changeset MUST reject values outside
this range.

#### Scenario: Confirm persists per-slot servings

- GIVEN a solved plan where Sunday's slot has `requested_servings: 10` and
  the rest of the week has `requested_servings: 4`
- WHEN the user confirms the plan
- THEN the persisted `ScheduledMeal` rows carry `servings: 10` for Sunday
  and `servings: 4` for every other day

#### Scenario: Out-of-cap servings rejected at the schema level

- GIVEN a changeset attempt with `servings: 25`
- WHEN the changeset is validated
- THEN it is invalid and the record is not persisted

### Requirement: proposal_json and optimizer payload carry per-slot servings

Each slot in `proposal_json` MUST carry a `requested_servings` field, and
`PayloadAdapter` MUST forward that same per-slot value into the
`OptimizerServer` payload sent to `optimizador.py`. No slot may be solved
using an implicit or globally-shared servings value.

#### Scenario: Payload reflects mixed servings across the week

- GIVEN a running constraint set with Sunday at 10 servings and the rest of
  the week at 4
- WHEN `PayloadAdapter` builds the optimizer payload
- THEN the payload contains a distinct `requested_servings` per slot
  matching the constraint set, not a single week-wide value

### Requirement: Optimizer scales candidate cost and macros by servings

`optimizador.py` MUST scale each candidate recipe's cost and macro values by
`requested_servings` (direct multiplication) before evaluating it against
budget and macro constraints. Candidate payload values
(`estimated_cost_cents`, `*_per_serving` macros) are ALREADY per single
serving (traced through `PriceService.fetch_recipe_prices_float/1` →
`price_per_serving_cents` and `Recipe`'s `_per_serving` fields), so the
solver MUST NOT divide by `recipe.servings` — doing so would double-apply
the per-serving normalization and undercount an 8-serving recipe's cost by
8x. The `requested_servings / recipe.servings` ratio applies ONLY to
whole-batch quantities (shopping items, inventory deduction — see the
requirements below). All constraint math (budget totals, macro bounds) MUST
operate on the scaled values. See design.md §2 for the two-factor analysis.

#### Scenario: Budget constraint sees the scaled cost for a 10-serving slot

- GIVEN a candidate whose payload carries a per-serving cost of `$2`
  (a 4-serving recipe whose whole batch costs `$8`)
- WHEN a slot requests `requested_servings: 10`
- THEN the candidate's cost used in the optimizer's budget constraint is
  `$2 * 10 = $20`, not the per-serving `$2` and not `$8 * (10 / 4)`
  applied to per-serving values

#### Scenario: Macro bounds scale consistently with cost

- GIVEN the same candidate with `protein_g_per_serving: 10`
- WHEN the optimizer evaluates the candidate for the 10-serving slot
- THEN the macro value used is `10g * 10 = 100g`

### Requirement: Shopping quantities scale linearly with requested servings

`ShoppingRepo.upsert_shopping_item/1` MUST scale `quantity_milli` by
`requested_servings / recipe.servings` for the associated slot instead of
copying `quantity_milli` unscaled. Packaging-aware rounding (rounding up to
whole packages) is explicitly out of scope for this change.

#### Scenario: 10-serving slot produces ~2.5x the quantity of a 4-serving slot

- GIVEN the same recipe scheduled once at `requested_servings: 4` and once
  at `requested_servings: 10`
- WHEN shopping items are upserted for both slots
- THEN the 10-serving slot's `quantity_milli` for each shared ingredient is
  `2.5x` the 4-serving slot's `quantity_milli` for that ingredient, using
  exact multiplication (no rounding to package sizes)

### Requirement: Cooking-completion inventory deduction scales by the same factor

`CookingService`'s inventory deduction on meal completion MUST apply the
same `requested_servings / recipe.servings` factor used at shopping-list
generation for that scheduled meal, so pantry deduction matches what was
actually purchased and cooked.

#### Scenario: Completing a 10-serving meal deducts scaled quantities

- GIVEN a `ScheduledMeal` with `servings: 10` for a recipe with base
  `servings: 4`
- WHEN the user marks the meal as cooked
- THEN inventory deduction removes `2.5x` the recipe's base per-ingredient
  quantities, matching the shopping-list scaling factor for that slot

### Requirement: Default servings from active account memberships

When no chat turn specifies a servings value for a date/slot, the system
MUST default `requested_servings` to the count of `:active`
`AccountMembership` rows for the account at solve time. This default MUST be
re-evaluated per solve (it is dynamic, not cached), so it reflects
membership changes (invites accepted, members removed) between sessions.

#### Scenario: No servings mentioned defaults to household size

- GIVEN an account with 4 `:active` memberships and no chat turn specifying
  guest count
- WHEN the solver runs
- THEN every unspecified slot defaults to `requested_servings: 4`

#### Scenario: Account with no active memberships defaults to 1

- GIVEN an account with zero `:active` `AccountMembership` rows (edge case:
  owner-only account mid-migration or suspended memberships only)
- WHEN the solver runs with no explicit servings override
- THEN `requested_servings` defaults to `1`, never `0`

#### Scenario: Membership change between sessions updates the default

- GIVEN an account had 4 `:active` memberships in a prior session
- WHEN a member is removed (membership becomes `:suspended`) before the next
  solve, leaving 3 `:active` memberships
- THEN the next solve's unspecified-slot default is `3`, not the
  previously cached `4`

## Cross-References

`account-membership` (source of the `:active` membership count),
`conversational-constraint-extraction` (servings range shared with the
`ConstraintDelta` changeset), `plan-narration` (assumption text for
defaulted servings).
