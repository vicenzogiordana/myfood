# Shopping Capability Spec

> **Source change**: `shopping-derived-from-confirmed-plan` (closes #36)
> **Parent spec**: #29 stories 14–17
> **Approved test seams**: planning channel integration, `Generation.Server` transaction, pure domain

## Source-of-truth mapping

| AC #36 | Story | Requirement | Test seam |
|---|---|---|---|
| #1 Expired Account denied | 17 | Expired Account cannot access the shopping list | HTTP controller + Channel |
| #2 Full-window rebuild | 14 | Locked confirm rebuilds the full-window shopping list | Generation.Server transaction |
| #3 Net shortage, no rounding | 16 | Net shortage is exact, normalized, and unrounded | Pure domain |
| #4 Provenance | 15 | Cart is derived only from confirmed scheduled meals and inventory | Pure domain + integration |

## Requirements

### Requirement: Expired Account MUST NOT access the shopping list

AC #36.1 / story 17: the enabled entitlement gate MUST cover both interfaces.

#### Scenario: [PR2] Expired HTTP read is refused
- GIVEN an expired membership; enforcement flag `true`
- WHEN it sends `GET /api/shopping-list`
- THEN it receives `403 {"error":"subscription_required"}` and no items

#### Scenario: [PR2] Expired confirmation push is refused
- GIVEN an expired membership; enforcement flag `true`
- WHEN it requests confirmation on `planning:<account_id>`
- THEN it receives `:subscription_required`; no `proposal_confirmed` broadcast arrives

#### Scenario: [PR2] Active Account is not falsely denied
- GIVEN an active membership; enforcement flag `true`
- WHEN it reads shopping and requests confirmation
- THEN both requests succeed without `:subscription_required`

### Requirement: Locked confirm MUST rebuild the full-window shopping list

AC #36.2 / story 14: successful confirm MUST atomically rebuild its Account-range.

#### Scenario: [PR2] Locked confirm includes every window meal
- GIVEN locked `[Day1,Day7]` with new and prior overlapping confirmed meals
- WHEN its proposal is confirmed
- THEN shopping reflects every scheduled meal in `[Day1,Day7]`

#### Scenario: [PR2] Rows retain per-meal parity without inventory
- GIVEN no inventory and one ingredient-unit per scheduled meal
- WHEN the locked proposal is confirmed
- THEN ShoppingItems equal scheduled meals, one per `(scheduled_meal_id, ingredient_id, unit)`

#### Scenario: [PR2] Failed rebuild leaves confirmation absent
- GIVEN a valid locked proposal with a forced ShoppingItem write failure
- WHEN confirmation is attempted
- THEN new `scheduled_meals`, ShoppingItems, and `:accepted` status are absent

#### Scenario: [PR1] Window wipe preserves terminal items
- GIVEN `:checked_out` and `:archived` items in the session window
- WHEN another proposal for that window is confirmed
- THEN both terminal items remain

#### Scenario: [PR2] Accepted proposal cannot rebuild again
- GIVEN an already accepted proposal
- WHEN it is confirmed again
- THEN `{:error, :already_confirmed}` and no CheckoutSession or ShoppingItem is created

### Requirement: Net shortage MUST be exact, normalized, and unrounded

AC #36.3 / story 16: the system MUST subtract by ingredient-unit, floor at zero, and never package-round.

#### Scenario: [PR1] Partial inventory yields the exact shortage
- GIVEN `200_000 quantity_milli :g` needed and `100_000` available
- WHEN the confirmed meal enters the cart
- THEN its row has `quantity_milli: 100_000`

#### Scenario: [PR1] Surplus inventory floors shortage at zero
- GIVEN `200_000 quantity_milli` needed and `300_000` available
- WHEN the confirmed meal enters the cart
- THEN no row exists for that ingredient-unit

#### Scenario: [PR1] Mixed recipe units remain separate
- GIVEN confirmed meals use milk once as `:ml`, once as `:g`
- WHEN their cart is rebuilt
- THEN two distinct ShoppingItems exist

#### Scenario: [PR1] Cart summary groups only matching units
- GIVEN persisted meal rows share an ingredient-unit
- WHEN the cart payload is read
- THEN one summary row has their exact sum and fewer rows than persistence

#### Scenario: [PR1] Exact differences are not rounded
- GIVEN flour needs `33_000 quantity_milli`; `10_000` is available
- WHEN the confirmed meal enters the cart
- THEN its row has `quantity_milli: 23_000`

### Requirement: Cart MUST derive only from confirmed scheduled meals and inventory

AC #36.4 / story 15: the system MUST NOT use AI text or unconfirmed content.

#### Scenario: [PR2] Proposal text cannot change an equivalent cart
- GIVEN differing proposal JSON with identical confirmed recipe IDs and inventory
- WHEN each confirmed cart payload is read
- THEN the payloads are byte-identical

#### Scenario: [PR2] Empty proposal creates an empty draft cart
- GIVEN a locked proposal with no slots
- WHEN it is confirmed
- THEN it reports zero items and its draft CheckoutSession has zero ShoppingItems

#### Scenario: [PR2] Pre-confirm read exposes no proposal-derived cart
- GIVEN no confirmed proposal for the current window
- WHEN `GET /api/shopping-list` is read
- THEN zero plan-derived ShoppingItems are returned

### Requirement: Shopping data MUST remain Account-isolated

The system MUST expose only ShoppingItems belonging to the caller's Account.

#### Scenario: [PR2] Another Account cannot read this cart
- GIVEN Account A has a rebuilt cart; Membership B is only on Account B
- WHEN Membership B reads shopping
- THEN no Account A ShoppingItem is visible
