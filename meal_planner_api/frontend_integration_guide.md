# Frontend Integration Guide (React Native)

This document is the integration reference for the current backend contracts in `meal_planner_api`.

## 1. Base URL and Transport

- Base HTTP URL (example local): `http://localhost:4000/api`
- Content-Type: `application/json`
- Auth for protected REST routes: `Authorization: Bearer <access_token>`
- WebSocket endpoint: `/socket/websocket`

## 2. Authentication

### 2.1 Issue access token

- Method: `POST`
- Path: `/api/auth/token`
- Auth required: No

Request body (minimum):

```json
{
  "provider": "google",
  "provider_user_id": "google-uid-123",
  "email": "user@example.com",
  "name": "Vicenzo",
  "subscription_tier": "free"
}
```

Notes:

- `subscription_tier` is optional in input, defaults to `free`.
- Tier is resolved server-side with RevenueCat before token generation.

Success response:

```json
{
  "access_token": "<jwt>",
  "token_type": "Bearer",
  "user": {
    "id": "...",
    "account_id": "..."
  },
  "account": {
    "id": "...",
    "subscription_tier": "free"
  },
  "subscription": {
    "tier": "free",
    "max_planning_days": 7
  },
  "websocket": {
    "path": "/socket/websocket",
    "params": {
      "token": "<jwt>"
    }
  }
}
```

Error response (`422`):

```json
{
  "error": "unable_to_issue_token"
}
```

### 2.2 Authenticated user endpoints

All routes below require:

```http
Authorization: Bearer <access_token>
```

If invalid/missing token, backend returns `401`:

```json
{
  "error": "unauthorized",
  "reason": "unauthenticated"
}
```

## 3. Account Context and Budget Inputs

### 3.1 Get account context

- Method: `GET`
- Path: `/api/account/context`

Success response:

```json
{
  "account_id": "...",
  "budget": {
    "account_id": "...",
    "weekly_limit_cents": 45000,
    "currency": "ARS"
  },
  "inventory_items": ["Tomate", "Pollo", "Arroz"],
  "subscription": {
    "max_planning_days": 7
  }
}
```

Notes:

- `budget` can be overridden by query params in planning-related flows (`weekly_budget_cents`, `currency`).
- `subscription.max_planning_days` controls planning limits.

### 3.2 Get current user

- Method: `GET`
- Path: `/api/me`

## 4. Planning (REST)

### 4.1 Weekly planning generation

- Method: `GET`
- Path: `/api/planning/weekly`
- Query params supported:
  - `kcal_target` (int)
  - `weekly_budget_cents` (int)
  - `currency` (string)
  - `days` (list, max constrained by plan)

Example:

```http
GET /api/planning/weekly?kcal_target=2200&weekly_budget_cents=60000&currency=ARS
```

Success response (`200`):

```json
{
  "data": {
    "account_type": "individual",
    "subscription_tier": "free",
    "days": [
      {
        "day": "monday",
        "meals": [
          {
            "slot": "breakfast",
            "recipe_id": "...",
            "label": "...",
            "estimated_cost_cents": 1200
          }
        ]
      }
    ],
    "notes": ["..."],
    "budget": {
      "account_id": "...",
      "weekly_limit_cents": 60000,
      "currency": "ARS"
    },
    "budget_within_limit": true,
    "estimated_total_cost_cents": 21500,
    "inventory_items": ["..."],
    "max_planning_days": 7
  }
}
```

Error responses:

- `400` for:
  - `invalid_payload`
  - `invalid_meals`
  - `duplicate_meal_slot`
  - `exceeds_max_planning_days`
- `422` for other planning errors.

Error format:

```json
{
  "error": "exceeds_max_planning_days"
}
```

### 4.2 Confirm selected plan

- Method: `POST`
- Path: `/api/planning/confirm`

Request body:

```json
{
  "meals": [
    {
      "date": "2026-03-30",
      "slot": "lunch",
      "recipe_id": "3f5b06a8-7a79-4b4a-95ca-89dff7f9c6f2"
    },
    {
      "date": "2026-03-30",
      "slot": "dinner",
      "recipe_id": "98f8de95-352e-4c25-b89a-c99db66b9003"
    }
  ]
}
```

Rules:

- Required keys per meal: `date`, `slot`, `recipe_id`
- Accepted slots: `breakfast`, `lunch`, `snack`, `dinner`
- No duplicate `{date, slot}` pairs

Success response:

```json
{
  "data": {
    "scheduled_meals_count": 2,
    "scheduled_meals": [
      {
        "id": "...",
        "date": "2026-03-30",
        "slot": "lunch",
        "recipe_id": "...",
        "is_cooked": false
      }
    ]
  }
}
```

## 5. Planning Chat (REST)

### 5.1 Generate proposal

- Method: `POST`
- Path: `/api/planning/chat`

Request body:

```json
{
  "message": "Quiero una semana barata y alta en proteina",
  "content_type": "text",
  "date_from": "2026-03-30",
  "date_to": "2026-04-05",
  "kcal_target": 2200,
  "weekly_budget_cents": 55000,
  "currency": "ARS",
  "days": ["monday", "tuesday", "wednesday"]
}
```

Success response:

```json
{
  "data": {
    "run_id": "...",
    "proposal_id": "...",
    "date_from": "2026-03-30",
    "date_to": "2026-04-05",
    "proposal": {
      "summary": "...",
      "scheduled_meals": [],
      "weekly_plan": {},
      "shopping_hints": []
    }
  }
}
```

### 5.2 Favorites

- Method: `GET`
- Path: `/api/planning/favorites?limit=10`

### 5.3 Confirm proposal

- Method: `POST`
- Path: `/api/planning/proposals/:proposal_id/confirm`

Success response:

```json
{
  "data": {
    "proposal_id": "...",
    "generation_run_id": "...",
    "scheduled_meals_count": 14,
    "status": "confirmed"
  }
}
```

### 5.4 Reject proposal

- Method: `POST`
- Path: `/api/planning/proposals/:proposal_id/reject`

Success response:

```json
{
  "data": {
    "proposal_id": "...",
    "generation_run_id": "...",
    "status": "rejected"
  }
}
```

Planning chat errors return `422` with:

```json
{
  "error": "<reason>"
}
```

## 6. Inventory (REST)

### 6.1 Get inventory view

- Method: `GET`
- Path: `/api/inventory`

Success response:

```json
{
  "data": {
    "sections": {
      "ok": [],
      "warning": [],
      "expired": []
    },
    "by_category": [],
    "extras": [],
    "totals": {
      "items_count": 12,
      "warning_count": 2,
      "expired_count": 1
    }
  }
}
```

Each inventory item contains:

- `id`
- `ingredient_id`
- `ingredient_name`
- `category`
- `quantity_milli`
- `unit`
- `source_kind`
- `acquired_at`
- `expired_at`
- `inferred_expired_at`
- `freshness_status`

### 6.2 Add extra item

- Method: `POST`
- Path: `/api/inventory/items/add-extra`

Request body:

```json
{
  "ingredient_id": "<ingredient_uuid>",
  "quantity_milli": 500,
  "unit": "g"
}
```

Valid units: `g`, `ml`, `unit`

### 6.3 Update quantity

- Method: `POST`
- Path: `/api/inventory/items/:item_id/quantity`

Request body:

```json
{
  "quantity_milli": 250
}
```

### 6.4 Dispose item

- Method: `POST`
- Path: `/api/inventory/items/:item_id/dispose`

Request body (optional reason):

```json
{
  "reason": "expired"
}
```

### 6.5 Voice flows

- Preview parse:
  - `POST /api/inventory/voice/preview`
- Apply operations:
  - `POST /api/inventory/voice/apply`

Preview request:

```json
{
  "text": "Use medio tomate y la mitad del kilo de pollo"
}
```

Apply request:

```json
{
  "raw_text": "Use medio tomate",
  "operations": [
    {
      "inventory_item_id": "...",
      "quantity_milli": 200
    }
  ]
}
```

### 6.6 Rescue planning from expiring ingredients

- Method: `POST`
- Path: `/api/planning/rescue`

Request body can use:

- `ingredient_ids` (array of ingredient UUIDs)
- `inventory_item_ids` (array of inventory item UUIDs)

## 7. Shopping (REST)

### 7.1 Get shopping list

- Method: `GET`
- Path: `/api/shopping-list`
- Query params:
  - `start_date` (ISO date, optional)
  - `end_date` (ISO date, optional)
  - `categories` (comma-separated categories, optional)
  - `optimize_prices` (`true`/`false`, optional)

Success response:

```json
{
  "data": {
    "date_from": "2026-03-30",
    "date_to": "2026-04-05",
    "recovery_mode": false,
    "pending_deliveries_count": 0,
    "optimize_prices": false,
    "grouped_by_category": [],
    "items": [
      {
        "ingredient_id": "...",
        "ingredient_name": "Tomate",
        "category": "verduras",
        "unit": "g",
        "total_quantity_milli": 1200,
        "rows_count": 3,
        "in_cart_rows": 1,
        "assigned_supermarket_id": null,
        "planned_dates": ["2026-03-30"],
        "estimated_total_cents": 3400
      }
    ],
    "totals": {
      "grouped_rows": 8,
      "pending_count": 6,
      "in_cart_count": 2
    }
  }
}
```

Important inventory-reservation behavior:

- Shopping generation uses only currently **available** inventory.
- Needed quantity is computed as: `missing = planned_needed - currently_available` per ingredient/unit.
- If inventory already covers the requirement, no shopping row is created for that ingredient.

### 7.2 Mark ingredient as in-cart / pending

- Method: `POST`
- Path: `/api/shopping-items/mark-cart`

Request body:

```json
{
  "ingredient_id": "<ingredient_uuid>",
  "in_cart": true,
  "start_date": "2026-03-30",
  "end_date": "2026-04-05"
}
```

### 7.3 Assign supermarket

- Method: `POST`
- Path: `/api/shopping-items/assign-supermarket`

Request body:

```json
{
  "ingredient_id": "<ingredient_uuid>",
  "supermarket_id": "<supermarket_uuid>",
  "start_date": "2026-03-30",
  "end_date": "2026-04-05"
}
```

### 7.4 Confirm checkout

- Method: `POST`
- Path: `/api/checkout/confirm`

Request body:

```json
{
  "checkout_type": "physical",
  "start_date": "2026-03-30",
  "end_date": "2026-04-05"
}
```

`checkout_type` values:

- `physical`: immediately moves quantities to inventory and marks rows checked out.
- `online`: marks rows `pending_delivery` (inventory is updated only on delivery confirmation).

Success response:

```json
{
  "data": {
    "checkout_session_id": "...",
    "status": "completed",
    "checkout_type": "physical",
    "moved_to_inventory_count": 4,
    "checked_out_items_count": 4,
    "grouped_by_supermarket": {
      "unassigned": {
        "item_count": 4,
        "total_cents": 12000,
        "item_ids": ["..."]
      }
    }
  }
}
```

### 7.5 Confirm online delivery arrived

- Method: `POST`
- Path: `/api/checkout/sessions/:checkout_session_id/delivered`

Success response:

```json
{
  "data": {
    "checkout_session_id": "...",
    "status": "completed",
    "moved_to_inventory_count": 4,
    "checked_out_items_count": 4
  }
}
```

Shopping errors are returned as `422` with:

```json
{
  "error": "<reason>"
}
```

## 8. WebSocket Integration (`planning_channel`)

## 8.1 Connect socket

Use token returned by `/api/auth/token`:

```ts
import { Socket } from "phoenix";

const socket = new Socket("ws://localhost:4000/socket/websocket", {
  params: { token: accessToken }
});

socket.connect();
```

If token is invalid or missing, socket connect is rejected.

## 8.2 Join topic

Topic format:

- `planning:<account_id>`

Example:

```ts
const channel = socket.channel(`planning:${accountId}`, {});

channel
  .join()
  .receive("ok", () => console.log("joined"))
  .receive("error", (err) => console.log("join error", err));
```

Join authorization rule:

- User can only join topic where `account_id` equals token user account.
- Forbidden join error payload:

```json
{
  "reason": "forbidden"
}
```

## 8.3 Outgoing events from backend

### `generation_started`

Emitted when generation begins.

Payload examples:

```json
{
  "request_id": "req_123"
}
```

or for constraints swap:

```json
{
  "request_id": "req_123",
  "reason": "constraint_update"
}
```

### `proposal_ready`

Emitted when proposal is generated/regenerated.

Payload:

```json
{
  "request_id": "req_123",
  "run_id": "...",
  "proposal_id": "...",
  "date_from": "2026-03-30",
  "date_to": "2026-04-05",
  "proposal": {
    "summary": "...",
    "scheduled_meals": [],
    "weekly_plan": {},
    "shopping_hints": []
  },
  "applied_constraints": {
    "kcal_target": 2200,
    "weekly_budget_cents": 50000,
    "currency": "ARS",
    "days": ["monday", "tuesday"]
  }
}
```

Note:

- `applied_constraints` is present on `swap_constraints` flow.

### `generation_error`

Emitted on generation failure.

Payload:

```json
{
  "request_id": "req_123",
  "reason": "invalid_date_range"
}
```

### `proposal_confirmed`

Broadcast when proposal is confirmed.

Payload:

```json
{
  "proposal_id": "...",
  "generation_run_id": "...",
  "scheduled_meals_count": 14,
  "status": "confirmed"
}
```

### `proposal_rejected`

Broadcast when proposal is rejected.

Payload:

```json
{
  "proposal_id": "...",
  "generation_run_id": "...",
  "status": "rejected"
}
```

## 8.4 Incoming events from client

### `generate_menu`

Payload accepted by channel:

```json
{
  "request_id": "req-client-1",
  "message": "Quiero menus baratos",
  "content_type": "text",
  "date_from": "2026-03-30",
  "date_to": "2026-04-05",
  "kcal_target": 2100,
  "weekly_budget_cents": 45000,
  "currency": "ARS",
  "days": ["monday", "tuesday", "wednesday"]
}
```

Channel reply:

- `{:ok, event}` with same payload shape as `proposal_ready`, or
- `{:error, %{request_id, reason}}`

If `request_id` is omitted, backend auto-generates one (`req_<number>`).

### `swap_constraints`

Payload:

```json
{
  "request_id": "req-client-2",
  "base_payload": {
    "message": "Mantener idea base",
    "content_type": "text",
    "date_from": "2026-03-30",
    "date_to": "2026-04-05",
    "kcal_target": 2100,
    "weekly_budget_cents": 45000,
    "currency": "ARS",
    "days": ["monday", "tuesday"]
  },
  "constraints": {
    "kcal_target": 2300,
    "weekly_budget_cents": 50000,
    "days": ["monday", "tuesday", "wednesday"]
  }
}
```

Behavior:

- Backend merges `constraints` into the base payload.
- Returns and broadcasts `proposal_ready` including `applied_constraints`.

### `confirm_proposal`

Payload:

```json
{
  "proposal_id": "<proposal_uuid>"
}
```

### `reject_proposal`

Payload:

```json
{
  "proposal_id": "<proposal_uuid>"
}
```

### Unknown events

For unsupported event name, channel reply error is:

```json
{
  "reason": "invalid_payload"
}
```

## 9. Recommended React Native Integration Sequence

1. `POST /api/auth/token` and persist `access_token` securely.
2. Configure HTTP client with `Authorization: Bearer <token>`.
3. Load `/api/account/context` for budget, inventory names, and plan limits.
4. Open socket with token and join `planning:<account_id>`.
5. Use `generate_menu` and optionally `swap_constraints` over channel for iterative UX.
6. Confirm proposal via channel (`confirm_proposal`) or REST (`/api/planning/proposals/:proposal_id/confirm`).
7. Show shopping view from `/api/shopping-list` and manage cart/checkout flows.
8. Update inventory using add/update/dispose/voice endpoints.

## 10. Error Handling Conventions

- Protected REST without valid auth: `401` with `{ "error": "unauthorized", "reason": "..." }`
- Validation/domain errors in most controllers: `422` with `{ "error": "<reason>" }`
- Planning weekly has explicit `400` for known request-shape/limits errors (including `exceeds_max_planning_days`).
- Channel generation errors are emitted and replied with `reason` as string.
