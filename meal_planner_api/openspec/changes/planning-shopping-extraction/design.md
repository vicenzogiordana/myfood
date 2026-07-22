# Design: planning-shopping-extraction

## 1. Technical Approach

On confirm, build the shopping cart by **pure-Elixir aggregation** of
`recipe_ingredients` for the confirmed proposal's scheduled meals, grouped by
`(ingredient_id, unit)`. No Python round-trip, no HTTP `PythonClient`, no Port
protocol change (approved option (c)). The cart write happens in the **same DB
transaction** as `persist_scheduled_meals/2`, scoped to `state.account_id`
(`current_membership.account_id`).

Layering follows the as-built split:

- **Read (data)**: a new query in `Data.RecipeRepo` loads `recipe_ingredients`
  for the confirmed recipe ids.
- **Aggregate (pure service)**: a new pure function in
  `Services.GenerationService` maps scheduled meals + their recipe ingredients
  into cart-line attr maps. No side effects (keeps GenerationService's contract).
- **Persist (data)**: existing `Data.ShoppingRepo.create_checkout_session/1` and
  `create_shopping_item/1`.
- **Orchestrate (server)**: a new private `persist_shopping_cart/2` in
  `Generation.Server`, invoked from `do_confirm/2` inside `Repo.transaction/1`.

## 2. As-built grounding (verified against code)

- `ShoppingItem`: requires `account_id, scheduled_meal_id, planned_date,
  ingredient_id, quantity_milli, unit, status`; `estimated_price_cents` optional
  (DB check `IS NULL OR >= 0`). Migration: `scheduled_meal_id` is `null: false`.
- `checkout_sessions`: `checkout_type` `null: false`, no default; DB check limits
  it to `('physical','online')`. `status` defaults to `draft`.
- `RecipeIngredient`: `quantity_milli:int`, `unit ∈ {:g,:ml,:unit}`, unique
  `(recipe_id, ingredient_id, unit)`.
- `ShoppingRepo.upsert_shopping_item/1` is **broken**: it casts a non-existent
  `:is_checked` field and targets `on_conflict (checkout_session_id,
  ingredient_id)` for which **no unique index exists** (the migration adds only a
  plain index on `checkout_session_id`). It would raise at runtime. Use
  `create_shopping_item/1` instead.
- `do_confirm/2` obtains tenancy from `state.account_id` (set at server init) and
  already gates on `verify_ownership(proposal_id, state.account_id)`. Scheduled
  meals returned by `persist_scheduled_meals/2` are structs carrying `.id`
  (binary_id), `.recipe_id`, `.date`.

## 3. Architecture Decisions (resolves the 5 open questions)

### Decision 1 — Aggregation grain vs. NOT-NULL `scheduled_meal_id` [load-bearing]

**Choice**: **Per-scheduled-meal rows.** One `ShoppingItem` per
`(scheduled_meal_id, ingredient_id, unit)`. No cross-meal dedup at persistence
time. `quantity_milli` = that meal's recipe quantity for the `(ingredient, unit)`
(summed only within the meal, which is a no-op given the RecipeIngredient unique
constraint). `planned_date = meal.date`, `scheduled_meal_id = meal.id`.

**Alternatives considered**: (a) per-session deduped rows summed across the week —
requires picking one `scheduled_meal_id` for a line spanning many meals
(semantically false) or making the FK nullable (a migration, more lines, breaks
`on_delete: :delete_all` cascade semantics). (b) `upsert_shopping_item/1` — broken
(Decision 2 grounding) and its conflict target would collapse cross-meal
ingredients and *replace* rather than sum.

**Rationale**: per-meal rows satisfy the NOT-NULL FK **cleanly and truthfully**
(every row genuinely belongs to one meal), avoid the broken upsert, need no
migration, and stay well within budget. **Dedup/summation becomes a read-time
concern**: cross-meal totals per `(ingredient_id, unit)` are computed when the
cart is read (a pure `summarize_cart/1` grouping) and surfaced in the confirm
reply/summary. This refines the proposal's "single merged line" success criterion
into a **presentation** guarantee (summary) rather than a **persistence-grain**
guarantee — the spec phase must encode it that way.

### Decision 2 — Mixed units

**Choice**: Group strictly by `(ingredient_id, unit)`. **No unit conversion.**
**Rationale**: `:g`↔`:ml` conversion needs per-ingredient density, and `:unit` is
a discrete count — none of that data exists in the model. Converting would
fabricate quantities. Same ingredient in `:g` and `:ml` yields two lines, by
design.

### Decision 3 — `CheckoutSession.checkout_type`

**Choice**: `:physical`. **Rationale**: the only allowed values are `:physical` /
`:online` (schema + DB check). The draft cart carries no supermarket assignment
or delivery integration (out of scope), so the neutral in-store default is
`:physical`; `:online` would imply a delivery slice that does not exist yet.

### Decision 4 — `estimated_price_cents`

**Choice**: leave `nil`. **Rationale**: optional field (DB allows NULL); pricing
from `recipe_prices`/`ingredient_prices` is a separate future slice. Populating it
now expands scope and line count for no confirm-flow value.

### Decision 5 — Re-confirm idempotency

**Choice**: guard on proposal status at the top of `do_confirm/2`. If
`proposal.status == :accepted`, return `{:error, :already_confirmed}` **before any
write**. **Rationale**: `do_confirm/2` currently re-runs on a second call and would
create a **second cart** (scheduled_meals are protected by the unique
`(account_id, date, slot)` index, but shopping_items have no such guard). A
status guard is the cheapest correct protection and needs no extra lookup. The
guard lives inside the transaction's precondition `with` chain so a concurrent
double-confirm still serializes on the proposal row.

## 4. Data Flow

    do_confirm(state, proposal_id)
      │  verify_ownership / fetch proposal+run
      │  guard: proposal.status == :accepted → {:error, :already_confirmed}
      ▼
    Repo.transaction:
      update_proposal(:accepted)
      persist_scheduled_meals ─► [ScheduledMeal{id, recipe_id, date}]
      persist_shopping_cart(scheduled_meals, state):
         RecipeRepo.list_ingredients_for_recipes(recipe_ids)   (read)
              └─► %{recipe_id => [{ingredient_id, unit, quantity_milli}]}
         GenerationService.build_cart_lines(meals, by_recipe)  (pure)
              └─► [%{scheduled_meal_id, planned_date, ingredient_id, unit, quantity_milli}]
         ShoppingRepo.create_checkout_session(%{account_id, status: :draft, checkout_type: :physical})
         Enum.each lines → ShoppingRepo.create_shopping_item(line + account_id + session_id)
              (any {:error, cs} → Repo.rollback)
      update_generation_run(:completed)
      ▼
    broadcast "proposal_confirmed" + {:ok, summary}; reset_state

## 5. Interfaces / Contracts

New pure function (`Services.GenerationService`):

```elixir
@spec build_cart_lines([ScheduledMeal.t()], %{integer => [map()]}) :: [map()]
# → [%{scheduled_meal_id, planned_date, ingredient_id, unit, quantity_milli}]
# meals with nil recipe_id, or recipes with no ingredients, contribute nothing

@spec summarize_cart([map()]) :: [map()]
# groups cart lines by {ingredient_id, unit}, sums quantity_milli (read-time dedup)
```

New read (`Data.RecipeRepo`):

```elixir
@spec list_ingredients_for_recipes([integer]) :: %{integer => [map()]}
# from ri in RecipeIngredient, where: ri.recipe_id in ^ids
#   → grouped by recipe_id; [] for absent recipes
```

Confirm reply / `proposal_confirmed` payload (extended):

```elixir
%{
  proposal_id: id,
  scheduled_meals_count: n,          # unchanged
  shopping_items_count: rows,        # NEW — count of persisted per-meal rows
  checkout_session_id: uuid,         # NEW
  cart: [%{ingredient_id, unit, quantity_milli}]  # NEW — deduped summary
}
```

## 6. Failure modes / error handling

| Case | Behavior |
|------|----------|
| Proposal already `:accepted` | `{:error, :already_confirmed}`, no writes (Decision 5) |
| Meal with `nil` recipe_id | contributes no cart lines; not an error |
| Recipe with no `recipe_ingredients` | contributes no cart lines; not an error |
| Empty proposal (no slots) | empty cart; draft session still created with 0 items, `shopping_items_count: 0` |
| Any `create_shopping_item` / session insert error | `Repo.rollback` → scheduled meals AND cart roll back atomically |
| Ownership fails | existing `{:error, :forbidden}` / `{:error, :not_found}` |

Note: `persist_scheduled_meals/2` currently swallows per-meal insert errors
(filters `match?({:ok, _})`). Moving the whole write-set under `Repo.transaction`
tightens atomicity for the cart; the pre-existing scheduled-meal swallow is out of
scope but flagged for the spec.

## 7. File Changes

| File | Action | Description |
|------|--------|-------------|
| `lib/meal_planner_api/generation/server.ex` | Modify | wrap `do_confirm/2` write-set in `Repo.transaction`; add status guard; add private `persist_shopping_cart/2`; extend broadcast + reply |
| `lib/meal_planner_api/services/generation_service.ex` | Modify | add pure `build_cart_lines/2` and `summarize_cart/1` |
| `lib/meal_planner_api/data/recipe_repo.ex` | Modify | add `list_ingredients_for_recipes/1` read query |
| tests (see §8) | Create | RED-first coverage |

No migration, no schema change, no new module, no HTTP.

## 8. Testing Strategy (strict TDD, behavior-first)

| Layer | What to test (behavior) | Approach |
|-------|-------------------------|----------|
| Unit (pure) | `build_cart_lines/2`: per-meal grain, shared ingredient across meals → one row per meal (not merged); mixed units → separate lines; nil recipe / no ingredients → empty | plain function tests, no DB |
| Unit (pure) | `summarize_cart/1`: cross-meal dedup + sum by `(ingredient_id, unit)` | plain function tests |
| Integration | confirm persists scheduled_meals **and** shopping_items in one transaction; forced item error rolls back both | Repo sandbox |
| Integration | every shopping_item scoped to `state.account_id`; `checkout_type: :physical`, `estimated_price_cents: nil`, `status: :pending` | Repo sandbox |
| Integration | re-confirm an `:accepted` proposal → `{:error, :already_confirmed}`, no second cart | Repo sandbox |
| Integration | empty proposal → draft session, `shopping_items_count: 0` | Repo sandbox |
| Contract | `proposal_confirmed` / reply includes `shopping_items_count`, `checkout_session_id`, `cart` | channel/broadcast assertion |

## 9. Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file
classification, or process-integration boundary. Pure-Elixir DB aggregation
within an existing transaction.

## 10. Migration / Rollout

No migration required. Additive to the confirm flow; existing `proposal_confirmed`
consumers ignore new payload keys. Rollback = revert the three file edits.

## 11. Open Questions

None blocking. Residual for spec/tasks: (a) whether the confirm reply's
`shopping_items_count` reports per-meal rows (chosen) vs. deduped lines — spec must
state per-meal rows + deduped `cart` summary; (b) the pre-existing
scheduled-meal error-swallow in `persist_scheduled_meals/2` is untouched here.
