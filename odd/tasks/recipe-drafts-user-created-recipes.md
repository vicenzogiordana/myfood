# Recipe Drafts and user-created recipes (issue #104, spec #93)

Locator: `odd/tasks/recipe-drafts-user-created-recipes.md` on branch
`feat/issue-104-recipe-drafts` (worktree `myfood-worktrees/issue-104`).
Engram mirror: `odd/recipe-drafts-user-created-recipes/tasks`.

## Objective

When existing recipes do not fit, the agent drafts a recipe with
`create_recipe` from catalog Ingredients only. Nutrition and cost are computed
by code and labelled partial when data is missing. Drafts live only in the
Workspace, are disclosed as AI-created, and confirming a Proposal that uses a
Draft saves it as a private AI-created Household Recipe. A Member can dictate a
recipe, built with the same rules, saved as a user-created Household Recipe
only through the explicit save action. `get_recipe` returns ingredients,
quantities, steps and nutrition completeness.

## Scope and constraints

- No agent tool writes persistent data; saving stays a human action
  (confirmation, save dictated recipe), revalidated by code.
- Unknown Ingredients are rejected; prices and nutrition are never invented
  (missing data is named, the result is `partial`).
- Drafts are in-memory Workspace state of the session process: ending the
  session unconfirmed discards them. Drafts never become Catalog Recipes
  (`account_id` is always the Household).
- A dictated (user-created) Draft is not plannable until the Member saves it;
  AI-created Drafts are plannable and saved only by confirmation.
- Model-provider spend and token caps stay per Planning Session (user decision
  2026-10-15); this feature adds no model calls of its own.

## Tasks

- [x] T1 `create_recipe` and `get_recipe` tools, Recipe Origin in recipe
      results (route: delegated direct — single bounded writer, this worker).
      Commit `bfcef10`. RED: recipe_tools_test 0/10; GREEN 10/10.
- [x] T2 Drafts in Proposals: optimizer candidates, validator, Purchase,
      Proposal origin; confirmation saves used Drafts as AI-created Household
      Recipes; Drafts vanish when the session ends unconfirmed.
      Commit `70e9041`. RED: recipe_draft_confirm_test 0/4; GREEN 4/4.
      Proposal meals gained `origin` and `draft` (session_meal_plan_test key
      assertion updated).
- [x] T3 Save dictated recipe human action (session + channel), Recipe Origin
      in the REST recipe listing, docs.
      Commit `96dc8c2`. RED: recipe_save_test 2/4 failing (save_recipe
      undefined), recipe origin REST test failing; GREEN all, channel 13/13.

## Acceptance criteria

- [x] create_recipe rejects unknown Ingredients and never invents prices or nutrition
- [x] Drafts disappear when the Planning Session ends unconfirmed
- [x] Confirmation saves used Drafts as AI-created Household Recipes, never as Catalog Recipes
- [x] Dictated recipes are saved only via the explicit save action, labelled user-created
- [x] Recipe Origin is visible wherever recipes are shown
- [x] get_recipe reports nutrition completeness

## Checks

- `MIX_TEST_PARTITION=104 MYFOOD_TEST_DATABASE=meal_planner_api_test_104 mix test`
  (config/test.exs does not append `MIX_TEST_PARTITION` to the database name;
  isolation uses `MYFOOD_TEST_DATABASE`)
- `mix precommit`

## Progress

- Baseline: `mix test test/meal_planner_api/planning_agent` 155 passed.
- Full suite (`MIX_TEST_PARTITION=104 MYFOOD_TEST_DATABASE=meal_planner_api_test_104
  mix test`): 1138 passed, 25 skipped, in four consecutive runs. One earlier
  `mix precommit` run reported 3 failures that did not reproduce (not
  captured); the rerun of `mix precommit` passed.
- RDD/native review not run by this worker; review gate is run separately.

## Design notes

- Drafts are in-memory Workspace state (`workspace.recipe_drafts`), keyed by
  a generated UUID that the saved recipe keeps, so Proposal meals reference
  the same id before and after confirmation.
- The validator, Restriction check and Purchase read Drafts from the context
  (`RecipeDraft.in_context/1`); confirmation inserts used AI-created Drafts in
  the same transaction, before the Planned Meals.
- A nutrient is reported only when every Ingredient has it per 100 g/ml;
  otherwise `nil` and stored as `nil` on save.
- Dictated Drafts are excluded from optimizer candidates and the validator
  until saved, so confirmation never saves them.

## Next step

Open the PR to main (Closes #104, Part of #93).
