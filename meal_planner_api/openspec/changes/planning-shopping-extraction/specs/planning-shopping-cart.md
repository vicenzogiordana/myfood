# Delta for Planning Shopping Cart

## ADDED Requirements

### Requirement: Confirming a proposal persists a shopping cart

`do_confirm/2` MUST, on confirming a proposal, aggregate `recipe_ingredients`
for the confirmed proposal's scheduled meals via pure-Elixir computation (no
HTTP/Python round-trip) and persist a draft `CheckoutSession` plus its
`ShoppingItem` rows in the **same DB transaction** as `scheduled_meals`
persistence. Cart rows MUST be scoped to `current_membership.account_id`
(`state.account_id`), never `user.account_id`.

#### Scenario: Confirm creates a draft cart scoped to the account

- GIVEN an authenticated membership with an unconfirmed, `:pending` proposal whose slots reference recipes with `recipe_ingredients`
- WHEN the client sends `confirm_proposal` with that `proposal_id` on the `planning:<account_id>` channel
- THEN a `CheckoutSession` is created with `status: :draft`, `checkout_type: :physical`, `estimated_price_cents: nil`, scoped to that membership's `account_id`
- AND one `ShoppingItem` per `(scheduled_meal_id, ingredient_id, unit)` is persisted, referencing that session and account

### Requirement: Shopping items persist at per-scheduled-meal grain

`ShoppingItem` rows MUST be created one per `(scheduled_meal_id, ingredient_id,
unit)` — no cross-meal summing at persistence time. This satisfies the
NOT-NULL `scheduled_meal_id` foreign key: every persisted row genuinely
belongs to exactly one scheduled meal. Cross-meal deduplication is a
**read-time summary** returned in the confirm reply, not a persisted merged
row.

#### Scenario: Same ingredient across two meals produces two persisted rows

- GIVEN a confirmed proposal with two scheduled meals whose recipes both use ingredient `flour` in unit `:g`
- WHEN the proposal is confirmed
- THEN two `ShoppingItem` rows are persisted, one per `scheduled_meal_id`, each referencing `flour`/`:g`
- AND the confirm reply's `cart` summary contains exactly one line for `(flour, :g)` with the combined `quantity_milli` of both meals

#### Scenario: Same ingredient in different units is not converted

- GIVEN a confirmed proposal where one meal's recipe uses `milk` in `:ml` and another meal's recipe uses `milk` in `:g`
- WHEN the proposal is confirmed
- THEN the persisted `ShoppingItem` rows keep `:ml` and `:g` as separate rows
- AND the confirm reply's `cart` summary contains two distinct lines for `(milk, :ml)` and `(milk, :g)` — no unit conversion is performed

#### Scenario: A recipe with no recipe_ingredients contributes no lines

- GIVEN a confirmed proposal with a scheduled meal whose recipe has zero `recipe_ingredients` rows
- WHEN the proposal is confirmed
- THEN that meal contributes no `ShoppingItem` rows
- AND this is not an error — the confirm call still succeeds

#### Scenario: Empty proposal yields an empty but valid cart

- GIVEN a confirmed proposal with no slots (no scheduled meals)
- WHEN the proposal is confirmed
- THEN a draft `CheckoutSession` is still created with zero `ShoppingItem` rows
- AND the reply reports `shopping_items_count: 0` — this is not an error

### Requirement: Re-confirming an already-accepted proposal is idempotent

If the target proposal's `status` is already `:accepted`, `do_confirm/2` MUST
return `{:error, :already_confirmed}` before performing any write, and MUST
NOT create a second `CheckoutSession` or any additional `ShoppingItem` rows.

#### Scenario: Confirming an already-accepted proposal is rejected without side effects

- GIVEN a proposal whose `status` is already `:accepted` (a prior successful confirm)
- WHEN `confirm_proposal` is sent again for that `proposal_id`
- THEN the call returns `{:error, :already_confirmed}`
- AND no new `CheckoutSession` or `ShoppingItem` rows are created

### Requirement: Cart persistence and scheduled-meal persistence are atomic

`ShoppingItem`/`CheckoutSession` creation and `scheduled_meals` persistence
MUST occur inside one `Repo.transaction/1`. A failure inserting any cart row
MUST roll back the scheduled-meal writes from the same confirm call, and vice
versa.

#### Scenario: Cart insert failure rolls back scheduled meals

- GIVEN a confirm call whose scheduled-meal persistence succeeds but a subsequent `ShoppingItem` insert fails (e.g. a constraint violation)
- WHEN `do_confirm/2` processes the failure
- THEN the transaction rolls back — no `scheduled_meals` rows and no cart rows from this call persist
- AND the proposal's `status` update is also rolled back (still not `:accepted`)

### Requirement: Cart data is isolated per account

`ShoppingItem` and `CheckoutSession` rows created by a confirm call MUST only
be visible/scoped to the confirming membership's `account_id`. A membership
on a different account MUST NOT see or read that cart.

#### Scenario: Cross-account isolation of a confirmed cart

- GIVEN Membership A on Account A confirms a proposal, creating a `CheckoutSession` and `ShoppingItem` rows scoped to Account A
- WHEN Membership B on Account B queries its own account's shopping items/sessions
- THEN Account A's `CheckoutSession` and `ShoppingItem` rows are not returned

### Requirement: The confirm reply and broadcast surface the cart

The `confirm_proposal` reply and the `proposal_confirmed` broadcast (channel
`planning:<account_id>`) MUST include `shopping_items_count` (the count of
persisted per-meal rows), `checkout_session_id`, and a deduped `cart` summary
(`[%{ingredient_id, unit, quantity_milli}]`), in addition to the existing
`scheduled_meals_count`.

#### Scenario: Confirm reply and broadcast include cart fields

- GIVEN a proposal that confirms successfully and produces cart lines
- WHEN the confirm completes
- THEN both the direct reply and the `proposal_confirmed` broadcast on `planning:<account_id>` include `shopping_items_count`, `checkout_session_id`, and `cart`
- AND `shopping_items_count` equals the number of persisted `ShoppingItem` rows (per-meal grain), while `cart` reflects the deduped `(ingredient_id, unit)` summary
