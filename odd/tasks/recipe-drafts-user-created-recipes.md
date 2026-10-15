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

- [ ] T1 `create_recipe` and `get_recipe` tools, Recipe Origin in recipe
      results (route: delegated direct — single bounded writer, this worker).
- [ ] T2 Drafts in Proposals: optimizer candidates, validator, Purchase,
      Proposal origin; confirmation saves used Drafts as AI-created Household
      Recipes; Drafts vanish when the session ends unconfirmed.
- [ ] T3 Save dictated recipe human action (session + channel), Recipe Origin
      in the REST recipe listing, docs.

## Acceptance criteria

- [ ] create_recipe rejects unknown Ingredients and never invents prices or nutrition
- [ ] Drafts disappear when the Planning Session ends unconfirmed
- [ ] Confirmation saves used Drafts as AI-created Household Recipes, never as Catalog Recipes
- [ ] Dictated recipes are saved only via the explicit save action, labelled user-created
- [ ] Recipe Origin is visible wherever recipes are shown
- [ ] get_recipe reports nutrition completeness

## Checks

- `MIX_TEST_PARTITION=104 MYFOOD_TEST_DATABASE=meal_planner_api_test_104 mix test`
  (config/test.exs does not append `MIX_TEST_PARTITION` to the database name;
  isolation uses `MYFOOD_TEST_DATABASE`)
- `mix precommit`

## Progress

- Baseline: `mix test test/meal_planner_api/planning_agent` 155 passed.
