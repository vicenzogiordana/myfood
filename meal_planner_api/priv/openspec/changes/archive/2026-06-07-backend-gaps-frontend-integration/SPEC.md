# SPEC: Backend Gaps — Frontend Integration

## Metadata
- **Change ID**: backend-gaps-frontend-integration
- **Phase**: spec
- **Created**: 2026-06-03
- **Author**: el Gentleman (orchestrator)
- **Status**: draft

---

## Gap 1: Slot-specific meal endpoint

### Problem
Frontend's Home view needs to show the selected `(date, slot)` meal in the card. The current `GET /api/calendar` returns a `selected_meal` but only based on server-side selection. Frontend drives the selection client-side and needs a dedicated lookup.

### Solution
Add a new controller action `show_slot` to `CalendarController` with query params `date` (ISO8601) and `slot` (breakfast|lunch|snack|dinner).

### Contract

**Endpoint**: `GET /api/calendar/slot?date=YYYY-MM-DD&slot=breakfast`

**Query Parameters**:
| Param | Type | Required | Description |
|---|---|---|---|
| `date` | string (ISO8601) | yes | Target date |
| `slot` | string | yes | One of: `breakfast`, `lunch`, `snack`, `dinner` |

**Success Response (200)**:
```json
{
  "data": {
    "meal_id": "uuid-string",
    "date": "2026-06-05",
    "slot": "lunch",
    "recipe_id": "uuid-string",
    "recipe_name": "Ensalada de tomate con lechuga",
    "is_cooked": false,
    "is_favorite": true,
    "can_create": false,
    "macros": { "calories": 120 },
    "prep_time_minutes": 10
  }
}
```

**Empty Response (200 — slot has no meal)**:
```json
{
  "data": {
    "meal_id": null,
    "date": "2026-06-10",
    "slot": "dinner",
    "recipe_id": null,
    "recipe_name": null,
    "is_cooked": false,
    "is_favorite": false,
    "can_create": true,
    "macros": null,
    "prep_time_minutes": null
  }
}
```

**Error Response (422)**:
```json
{ "error": "invalid_date_format" | "invalid_slot" }
```

**Business Rules**:
- `can_create: true` only when `meal_id == null` (empty slot)
- Always checks `selected_slot` and `selected_date` params against auth — returns 401 if token invalid
- Slot value normalized to atom internally (`String.to_existing_atom/1`)

---

## Gap 2: Favorites as optimization hints

### Problem
`GenerationServer` and `GenerationService.build_constraints/2` do not receive favorite recipes as optimization hints. The optimizer can prioritize them but has no signal.

### Solution
Extend `GenerationService.build_constraints/2` to accept a new optional key `favorite_recipe_ids` and inject it into the slots input sent to OR-Tools.

### Changes

**GenerationService.build_constraints/2**
- Accept `favorite_recipe_ids: [recipe_id, ...]` from the constraints map
- Pass through to `build_slots_input/1`
- In each slot's `"constraints"`, add `"preferred_recipe_ids": [...]`

**GenerationServer.run_pipeline/1**
- Before calling `build_slots_input`, call `load_favorite_recipe_ids(user_id)` from `RecipeRepo`

**GenerationServer.build_slots_input/1**
- Include `"preferred_recipe_ids"` in each slot's constraints dict

**OR-Tools payload (new field in each slot)**:
```json
{
  "date": "2026-06-05",
  "slot": "lunch",
  "available_recipe_ids": [1, 2, 3],
  "constraints": {
    "preferred_recipe_ids": [2, 5],
    "budget_cents": 10000,
    "protein_g": 25,
    "excluded_recipe_ids": [],
    "excluded_ingredients": []
  }
}
```

**Note**: The Python optimizer is responsible for scoring preferred recipes higher. This is a schema injection, not a backend logic change.

---

## Gap 3: can_create flag in slot response

### Problem
Frontend's Home view needs to know if the `+` button should be enabled (slot is empty) or disabled (slot has a meal).

### Solution
Already partially addressed in Gap 1 (`can_create` field in response). Ensure `CalendarController.index` (full monthly overview) also returns `can_create` per meal in the `meals` list and in `selected_meal`.

### Changes

**CalendarController.serialize_meal/1**
Add `can_create: false` to every serialized meal.

**CalendarController.serialize_selected_meal/1**
Add `can_create: meal.recipe_id == nil` (true if slot is empty).

**New field in existing CalendarController.index response**:
```json
{
  "data": {
    "selected_meal": {
      "meal_id": "uuid",
      "can_create": false,
      ...
    },
    "meals": [
      { "meal_id": "uuid", "can_create": false, ... }
    ]
  }
}
```

---

## Gap 4: Shopping → Inventory auto-movement on checkout

### Problem
`ShoppingService.confirm_checkout/3` updates the checkout session to `completed` but does not move items to inventory. The `move_items_to_inventory/1` function exists but is not called from `confirm_checkout`.

### Solution
Call `move_items_to_inventory/1` inside `confirm_checkout/3` after updating session status. Wrap in transaction.

### Changes

**ShoppingService.confirm_checkout/3**

Current flow:
```elixir
{:ok, updated} = ShoppingRepo.update_checkout_session(...)
{:ok, serialize_checkout_session(updated)}
```

New flow:
```elixir
Repo.transaction(fn ->
  {:ok, updated} = ShoppingRepo.update_checkout_session(...)

  # Get checked-out items for this session
  items = Shopping.list_items_by_session(updated.account_id, session_id)
          |> Enum.filter(&(&1.status == :checked_out))

  moved_count = move_items_to_inventory(items)

  %{updated | moved_to_inventory_count: moved_count}
end)
|> case do
  {:ok, result} -> {:ok, serialize_checkout_with_inventory(result)}
  {:error, _} -> {:error, :transaction_failed}
end
```

**Shopping.list_items_by_session/2** (new function in Persistence.Shopping):
```elixir
def list_items_by_session(account_id, session_id) do
  from(i in ShoppingItem,
    where: i.account_id == ^account_id,
    where: i.checkout_session_id == ^session_id
  )
  |> Repo.all()
end
```

**Return type enriched**:
```json
{
  "checkout_session": {
    "id": "uuid",
    "status": "completed",
    "moved_to_inventory_count": 5,
    "total_items": 5
  }
}
```

---

## Gap 5: Auto-pruning of expired shopping items

### Problem
Shopping items whose planned date has passed remain visible. Frontend expects them to be hidden.

### Solution
Existing `prune_past_items/2` in `ShoppingService` already archives items with `status: :archived` when `planned_date < from_date`. The gap is that this only runs when `get_shopping_list/2` is called with a `from_date` in the future. Need to ensure it also runs for the default case and on every list load.

### Changes

**ShoppingService.get_shopping_list/2**
- Make `prune_past_items` run always (not only when `from_date > today`)

**Persistence.Shopping.list_pending_items_with_context/3**
- Add a where clause to exclude `status: :archived` items by default

**Backend behavior**:
- Items with `planned_date < today` and `status: :pending` → auto-archived on next list load
- Items with `status: :archived` → excluded from list response unless `?include_archived=true`
- No hard delete — soft archive for audit trail

**API change**: `GET /api/shopping-list?include_archived=true` returns archived items for debugging.

---

## Gap 6: WebSocket auth documentation

### Problem
Frontend team needs to know the exact handshake flow for Phoenix Channels.

### Solution
Add inline documentation in `meal_planner_api_web/user_socket.ex` and create a `CHANNELS.md` artifact.

### Files Changed

**user_socket.ex** — expand docstring:
```elixir
defmodule MealPlannerApiWeb.UserSocket do
  @moduledoc """
  Phoenix Socket for real-time communication.

  ## Authentication

  On the client, pass the JWT token from Guardian during socket connect:

  ```javascript
  // React Native / JavaScript
  import { Socket } from "phoenix";

  const socket = new Socket("wss://your-api.com/socket", {
    params: { token: your_jwt_token }
  });

  socket.connect();

  // Join a channel
  const channel = socket.channel("calendar:ACCOUNT_ID", {});
  channel.join();
  ```

  ## Available Channels

  | Channel | Purpose | Events |
  |---|---|---|
  | `ai_chat:ROOM_ID` | AI chat streaming | `new_message` → `ai_response` |
  | `calendar:ACCOUNT_ID` | Calendar realtime | `meal_updated`, `meal_deleted`, `favorite_toggled` |
  | `planning:ACCOUNT_ID` | Planning generation | `generate_menu`, `proposal_ready`, `confirm_proposal` |
  | `cooking:ACCOUNT_ID_SESSION` | Cooking session | `start_session`, `ask_assistant` |

  ## Token Refresh

  If the token expires mid-session, the socket will disconnect.
  The client should listen for `Phoenix.Socket.CloseEvent` and reconnect
  with a fresh token.
  """
```

**New file: `docs/CHANNELS.md`** (in repo root or `meal_planner_api/docs/`):
```
meal_planner_api/docs/CHANNELS.md
```

Full channel reference with:
- All incoming/outgoing events
- Payload shapes for each event
- Error handling patterns
- Reconnection strategy

---

## Summary of Changes by File

| File | Change | Gap |
|---|---|---|
| `lib/meal_planner_api_web/controllers/calendar_controller.ex` | Add `show_slot` action | 1, 3 |
| `lib/meal_planner_api/persistence/calendar.ex` | Add `get_slot_meal/3` function | 1, 3 |
| `lib/meal_planner_api/services/generation_service.ex` | Accept and propagate `favorite_recipe_ids` | 2 |
| `lib/meal_planner_api/generation/server.ex` | Load favorites, inject into slots | 2 |
| `lib/meal_planner_api/services/shopping_service.ex` | Call `move_items_to_inventory` in `confirm_checkout` | 4 |
| `lib/meal_planner_api/services/shopping_service.ex` | Fix `prune_past_items` to always run | 5 |
| `lib/meal_planner_api/persistence/shopping.ex` | Add `list_items_by_session/2`, `list_pending_items_with_context` exclude archived | 4, 5 |
| `lib/meal_planner_api_web/user_socket.ex` | Expand docstring with usage examples | 6 |
| `docs/CHANNELS.md` | Full channel reference | 6 |
| `priv/openspec/changes/backend-gaps-frontend-integration/SPEC.md` | This file | — |

---

## Open Questions (resolved in this spec)

| Question | Resolution |
|---|---|
| Gap 6 — separate doc or inline? | Both: expanded docstring + `docs/CHANNELS.md` |
| Auto-pruning retention policy? | Soft delete (`status: :archived`). `include_archived=true` for debugging. |
| Favorites injection mechanism? | Schema injection via `preferred_recipe_ids` in each slot's constraints |
| Checkout → Inventory atomic? | Yes, wrapped in `Repo.transaction/1` |