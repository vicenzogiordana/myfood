# Ingredient Tags and Restriction validator

Issue: #94 (part of spec #93). Branch: `feat/issue-94-ingredient-tags`.

## Objective

Catalog Ingredients carry reviewed Ingredient Tags. Every Restriction (allergy or
diet) maps to a fixed set of forbidden Ingredient Tags, and one deterministic
validator checks a set of meals against every Member's Restrictions, honouring
approved Absence Exceptions, with conflict messages that never name the Member.

## Problem / why

Today a Member's allergies are per-ingredient exclusions and diets are not
enforced at all. The culinary agent (#93) needs one code-owned check so that a
plan breaking an allergy or diet is never presented as valid, and only reviewed
catalog data (never AI output at validation time) decides it.

## Scope

- `ingredient_tags` table + `IngredientTag` schema with `suggested`/`reviewed` status.
- Catalog functions: tag (reviewed), suggest (unreviewed), accept a suggestion,
  load reviewed tags per recipe.
- `MealPlannerApi.Planning.Restrictions`: tag vocabulary and Restriction -> forbidden tags.
- `MealPlannerApi.Planning.RestrictionValidator`: validate meals against Members'
  Restrictions with Absence Exceptions as input.

Out of scope: loading Member Restrictions from profiles, storing Member allergen
Restrictions, AI tag-suggestion pipeline, the classification pass over the catalog,
budget/coverage/variety checks of the unified validator (later slices of #93).

## Constraints

- Only reviewed tags count; suggestions never affect validation.
- Disliked ingredients (Preferences) are never violations.
- Conflict output carries no Member reference.
- Tests go through public interfaces with fictitious fixtures.

## Tasks

- [ ] T1 Ingredient Tags storage: tag, suggest, accept, reviewed tags per recipe (route: inline; single writer, no delegation in bounded worker)
- [ ] T2 Restriction -> forbidden tag mapping (vegetarian, vegan, pescatarian, celiac, omnivore, allergy)
- [ ] T3 Restriction validator with Absence Exceptions and generic conflicts
- [ ] T4 Docs: CONTEXT.md note on forbidden-tag mapping

## Acceptance criteria

- [ ] Ingredients can be tagged, and tag suggestions are stored as unreviewed until a reviewer accepts them
- [ ] Diet-to-forbidden-tag mapping covers vegetarian, vegan, pescatarian and celiac; omnivore forbids nothing
- [ ] Validator rejects a meal whose recipe ingredients carry a tag forbidden by any Member's Restriction
- [ ] An Absence Exception lifts exactly its Restriction for exactly its meals and nothing else
- [ ] Disliked ingredients are never treated as violations
- [ ] Conflict messages never reveal which Member holds the Restriction
- [ ] Tests exercise the validator through its public interface with fictitious fixtures

## Checks

- `MIX_TEST_PARTITION=94 MYFOOD_TEST_DATABASE=meal_planner_api_test94 mix test`
- `mix precommit` (same env)

## Progress / evidence

See commit log of the branch; filled in on completion.
