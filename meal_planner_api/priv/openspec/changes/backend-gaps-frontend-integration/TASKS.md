# SDD TASKS: Backend Gaps — Frontend Integration

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~434 production + ~225 tests = **~659 total** |
| 400-line budget risk | **High** (659 > 400) |
| Chained PRs recommended | **Yes** |
| Suggested split | **4 PRs chained** (Module 1 → Module 2 → Module 3 → Module 4) |
| Delivery strategy | ask-on-risk |
| Chain strategy | stacked-to-main |

```
Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High
```

---

## PR Strategy

El cambio total supera las 400 líneas (~659 líneas). Se recomienda encadenar 4 PRs independientes por dominio funcional. Cada PR es atómico, verificable y no rompe el main.

| PR | Módulo | Archivos | Líneas est. |
|----|--------|----------|-------------|
| PR 1 | **Calendar** (G1 + G3) | CalendarController, Persistence.Calendar, Router, tests | ~190 |
| PR 2 | **Generation** (G2) | GenerationService, GenerationServer, RecipeRepo, tests | ~130 |
| PR 3 | **Shopping** (G4 + G5) | ShoppingService, Persistence.Shopping, tests | ~125 |
| PR 4 | **Docs** (G6) | UserSocket, docs/CHANNELS.md | ~215 |

---

## TASK-LIST

### MÓDULO 1 — Calendar (Gap 1 + Gap 3)

#### TASK-1
- **ID**: TASK-1
- **Subject**: Add test specs for CalendarController slot endpoint
- **Description**: Add unit tests covering `GET /api/calendar/slot` for filled slot (returns `can_create: false`), empty slot (returns `can_create: true`), and validation errors (invalid date → 422, invalid slot → 422, missing params → 422). Also test that `GET /api/calendar` response includes `can_create` in `selected_meal` and `meals` list.
- **Files to change**:
  - `test/meal_planner_api_web/controllers/calendar_controller_test.exs`
- **Estimated changed lines**: ~90
- **Dependencies**: None
- **Status**: pending

#### TASK-2
- **ID**: TASK-2
- **Subject**: Add test specs for Persistence.Calendar slot query
- **Description**: Add unit tests for `Persistence.Calendar.get_slot_meal/3`: returns map when meal exists, returns `nil` when slot is empty, includes recipe name and favorite status via joins.
- **Files to change**:
  - `test/meal_planner_api/persistence/calendar_test.exs`
- **Estimated changed lines**: ~35
- **Dependencies**: None
- **Status**: pending

#### TASK-3
- **ID**: TASK-3
- **Subject**: Implement get_slot_meal/3 in Persistence.Calendar
- **Description**: Add `get_slot_meal/3` query function to `Persistence.Calendar`. Uses `left_join` on `SlotFavorite` (not FavoriteRecipe) to check if the slot is favorited. Returns a flat map with `id`, `date`, `slot`, `is_cooked`, `recipe_id`, `recipe_name`, `calories_per_serving`, `prep_time_minutes`, `is_favorite`. Returns `nil` if no meal exists.
- **Files to change**:
  - `lib/meal_planner_api/persistence/calendar.ex`
- **Estimated changed lines**: ~25
- **Dependencies**: TASK-2 (test order: RED first)
- **Status**: pending

#### TASK-4
- **ID**: TASK-4
- **Subject**: Update CalendarController serializers and add show_slot action
- **Description**: Three changes: (1) Add `can_create: false` to `serialize_meal/1` map. (2) Update `serialize_selected_meal/1` to derive `can_create` from `is_nil(meal.recipe_id)`. (3) Add `show_slot/2` action that parses `date` and `slot` query params, calls `Calendar.get_slot_meal/3`, and calls `serialize_slot_response/3` which returns empty-slot shape (meal_id nil, can_create true) or filled-slot shape (meal + can_create false).
- **Files to change**:
  - `lib/meal_planner_api_web/controllers/calendar_controller.ex`
- **Estimated changed lines**: ~60
- **Dependencies**: TASK-1, TASK-3
- **Status**: pending

#### TASK-5
- **ID**: TASK-5
- **Subject**: Add route GET /api/calendar/slot in Router
- **Description**: Add `get("/calendar/slot", CalendarController, :show_slot)` in the `:auth` scope, after the existing `/calendar` route. Route path is distinct from `/calendar` so no conflict.
- **Files to change**:
  - `lib/meal_planner_api_web/router.ex`
- **Estimated changed lines**: ~2
- **Dependencies**: TASK-4
- **Status**: pending

---

### MÓDULO 2 — Generation (Gap 2)

#### TASK-6
- **ID**: TASK-6
- **Subject**: Add test specs for GenerationService favorite_recipe_ids propagation
- **Description**: Add tests: (1) `build_constraints` with nil payload returns `favorite_recipe_ids: []`. (2) With string-keyed payload, propagates favorites. (3) With atom-keyed payload, propagates favorites. (4) `build_slots_input` receives constraints with `favorite_recipe_ids` and produces slots with `"preferred_recipe_ids"` as string list.
- **Files to change**:
  - `test/meal_planner_api/services/generation_service_test.exs`
- **Estimated changed lines**: ~30
- **Dependencies**: None
- **Status**: pending

#### TASK-7
- **ID**: TASK-7
- **Subject**: Add test specs for GenerationServer favorites loading and slot injection
- **Description**: Add test for `run_pipeline` behavior: when favorites exist for account, `build_slots_input` output includes `preferred_recipe_ids` (as string IDs) in every slot's constraints dict.
- **Files to change**:
  - `test/meal_planner_api/generation/server_test.exs`
- **Estimated changed lines**: ~25
- **Dependencies**: None
- **Status**: pending

#### TASK-8
- **ID**: TASK-8
- **Subject**: Add list_favorite_ids/1 query to RecipeRepo
- **Description**: Add new query function `list_favorite_ids/1` in `RecipeRepo`. Returns `[%{id: recipe_id}]` for all favorited recipes for the given `account_id`. Used by `GenerationServer` to load favorite IDs before building OR-Tools payload.
- **Files to change**:
  - `lib/meal_planner_api/data/recipe_repo.ex`
- **Estimated changed lines**: ~10
- **Dependencies**: None
- **Status**: pending

#### TASK-9
- **ID**: TASK-9
- **Subject**: Update GenerationService.build_constraints to propagate favorite_recipe_ids
- **Description**: Update both overloads of `build_constraints/2`: (1) nil payload returns `favorite_recipe_ids: []`. (2) With payload, reads from both `payload["favorite_recipe_ids"]` and `payload[:favorite_recipe_ids]`, falls back to resolved default.
- **Files to change**:
  - `lib/meal_planner_api/services/generation_service.ex`
- **Estimated changed lines**: ~15
- **Dependencies**: TASK-6
- **Status**: pending

#### TASK-10
- **ID**: TASK-10
- **Subject**: Update GenerationServer to load favorites and inject preferred_recipe_ids into slots
- **Description**: Two changes: (1) Rename `load_user_profile/1` usage to `load_user_profile_and_favorites/2`, which returns `{profile, favorite_ids}`. In `run_pipeline/1`, inject `favorite_recipe_ids` into the resolved constraints map via `Map.put/3`. (2) In `build_slots_input/1`, extract `favorite_recipe_ids` from constraints (atom key), convert to strings, inject as `"preferred_recipe_ids"` in each slot's constraints dict.
- **Files to change**:
  - `lib/meal_planner_api/generation/server.ex`
- **Estimated changed lines**: ~40
- **Dependencies**: TASK-7, TASK-8, TASK-9
- **Status**: pending

---

### MÓDULO 3 — Shopping (Gap 4 + Gap 5)

#### TASK-11
- **ID**: TASK-11
- **Subject**: Add test specs for ShoppingService checkout transaction and shopping list pruning
- **Description**: Add test for `confirm_checkout/3`: (1) wraps in transaction and calls `move_items_to_inventory`, (2) returns `moved_to_inventory_count` in response, (3) rolls back and returns `{:error, :transaction_failed}` on session update failure. Add test for `get_shopping_list/2`: (1) archives past-dated pending items on every call, (2) excludes archived by default, (3) includes archived when `include_archived=true`.
- **Files to change**:
  - `test/meal_planner_api/services/shopping_service_test.exs`
- **Estimated changed lines**: ~90
- **Dependencies**: None
- **Status**: pending

#### TASK-12
- **ID**: TASK-12
- **Subject**: Add test specs for Persistence.Shopping list_items_by_session
- **Description**: Add tests for `list_items_by_session/2`: returns all items for a given `checkout_session_id`, handles empty session (returns empty list).
- **Files to change**:
  - `test/meal_planner_api/persistence/shopping_test.exs`
- **Estimated changed lines**: ~20
- **Dependencies**: None
- **Status**: pending

#### TASK-13
- **ID**: TASK-13
- **Subject**: Implement list_items_by_session/2 and update list_items_for_account/2 in Persistence.Shopping
- **Description**: Two changes: (1) Add `list_items_by_session/2` query — filters `ShoppingItem` by `account_id` and `checkout_session_id`, returns all items (no date filter). (2) Update `list_items_for_account/1` to accept optional keyword list with `include_archived` option (default `false`). When false, adds `where: status != :archived` to query.
- **Files to change**:
  - `lib/meal_planner_api/persistence/shopping.ex`
- **Estimated changed lines**: ~27
- **Dependencies**: TASK-12
- **Status**: pending

#### TASK-14
- **ID**: TASK-14
- **Subject**: Update ShoppingService confirm_checkout, get_shopping_list, and serialize_checkout_session
- **Description**: Three changes: (1) `confirm_checkout/3` — wrap session update + inventory movement in `Repo.transaction/1`. Inside transaction: get checked-out items via `list_items_by_session`, filter by `status == :checked_out`, call `move_items_to_inventory`, attach `moved_to_inventory_count` to session struct. On success, return enriched response. On error, return `{:error, :transaction_failed}`. (2) `get_shopping_list/2` — call `prune_past_items(account_id, Date.utc_today())` instead of `prune_past_items(account_id, from_date)`. (3) `serialize_checkout_session/1` — add `moved_to_inventory_count` and `total_items` fields using `Map.get(s, field, 0)`.
- **Files to change**:
  - `lib/meal_planner_api/services/shopping_service.ex`
- **Estimated changed lines**: ~35
- **Dependencies**: TASK-11, TASK-13
- **Status**: pending

---

### MÓDULO 4 — Documentation (Gap 6)

#### TASK-15
- **ID**: TASK-15
- **Subject**: Expand UserSocket module docstring with auth, channels, and token refresh guidance
- **Description**: Replace existing `@moduledoc` with expanded documentation including: (1) Authentication section with JavaScript client example using Phoenix Socket, (2) Channels table mapping channel names to purposes and events, (3) Token refresh section explaining reconnection on token expiry, (4) Disconnection section referencing Phoenix Channels presence cleanup.
- **Files to change**:
  - `lib/meal_planner_api_web/user_socket.ex`
- **Estimated changed lines**: ~35
- **Dependencies**: None
- **Status**: pending

#### TASK-16
- **ID**: TASK-16
- **Subject**: Create docs/CHANNELS.md with full Phoenix Channels reference
- **Description**: Create new file `docs/CHANNELS.md` containing full reference for all 4 channels: `ai_chat:*`, `calendar:*`, `planning:*`, `cooking:*`. For each channel: description, incoming events with JSON payload shapes, outgoing events with JSON response shapes. Include reconnection strategy section with JavaScript example and error handling patterns table.
- **Files to change**:
  - `docs/CHANNELS.md`
- **Estimated changed lines**: ~180
- **Dependencies**: None
- **Status**: pending

---

## Implementation Order

```
PR 1 — Calendar (G1 + G3):
  TASK-1 → TASK-2 → TASK-3 → TASK-4 → TASK-5

PR 2 — Generation (G2):
  TASK-6 → TASK-7 → TASK-8 → TASK-9 → TASK-10

PR 3 — Shopping (G4 + G5):
  TASK-11 → TASK-12 → TASK-13 → TASK-14

PR 4 — Docs (G6):
  TASK-15 → TASK-16
```

---

## Line Count Breakdown per PR

| PR | Module | Files | Est. Lines | 400-line verdict |
|----|--------|-------|------------|-----------------|
| PR 1 | Calendar | 5 files (3 impl + 2 test) | ~212 | WITHIN_BOUNDS |
| PR 2 | Generation | 5 files (3 impl + 2 test) | ~130 | WITHIN_BOUNDS |
| PR 3 | Shopping | 4 files (2 impl + 2 test) | ~172 | WITHIN_BOUNDS |
| PR 4 | Docs | 2 files (2 impl, no test) | ~215 | WITHIN_BOUNDS |
| **Total** | All | **14 files** | **~729** | — |

> **Nota**: Los tests de TASK-2 y TASK-12 podrían fusionarse en un solo archivo de test por capa si el repositorio sigue una convención de un solo archivo de test por módulo. Si es el caso, las líneas por PR serían ~195, ~128, ~165, ~215 respectivamente — todos dentro del umbral.

---

## Key Verification Points

| Task | Verification |
|------|-------------|
| TASK-3 | `Persistence.Calendar.get_slot_meal/3` returns nil for empty slot; includes `is_favorite` via SlotFavorite join |
| TASK-4 | Empty slot → `can_create: true`; filled slot → `can_create: false`; invalid slot → 422 |
| TASK-9 | `build_constraints` with payload having `"favorite_recipe_ids"` returns that list |
| TASK-10 | Each slot in OR-Tools payload has `"preferred_recipe_ids"` as list of strings |
| TASK-13 | `list_items_by_session` returns all items for session, not just pending |
| TASK-14 | `confirm_checkout` returns `moved_to_inventory_count`; pruning uses `Date.utc_today()` |
| TASK-16 | `docs/CHANNELS.md` renders under `docs/` and `mix docs` includes it |

---

*Documento de tareas generado a partir de DESIGN.md — SDD phase: tasks*