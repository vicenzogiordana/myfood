# Phoenix Channels Reference

This document provides a complete reference for all Phoenix Channels used in the Meal Planner API real-time communication layer.

## Overview

The application uses Phoenix Channels for real-time bidirectional communication between the Elixir backend and JavaScript frontend clients. All channels are accessed through a single authenticated `UserSocket` connection.

## Connection

```javascript
import { Socket } from "phoenix";

const socket = new Socket("/socket", {
  params: { token: "<jwt-token>" }
});

socket.connect();
```

## Channel Reference

### ai_chat:* — AI Meal Planning Assistant

Conversational AI assistant for meal planning queries.

**Topic Pattern:** `ai_chat:<session_id>`

#### Incoming Events

| Event | Payload | Description |
|-------|---------|-------------|
| `new_message` | `{"content": "string", "context": {...}}` | Send a message to the AI assistant |
| `regenerate` | `{"message_id": "uuid", "options": {...}}` | Request regeneration of an AI response |
| `end_session` | `{}` | End the AI chat session and cleanup |

**Example Payload (new_message):**
```json
{
  "content": "What can I make with chicken and rice?",
  "context": {
    "dietary_restrictions": ["gluten-free"],
    "servings": 4
  }
}
```

#### Outgoing Events

| Event | Payload | Description |
|-------|---------|-------------|
| `new_message` | `{"id": "uuid", "content": "string", "role": "assistant", "timestamp": "ISO8601"}` | AI response |
| `typing` | `{"is_typing": true}` | Indicator that AI is processing |
| `error` | `{"code": "string", "message": "string"}` | Error occurred |
| `regeneration_started` | `{"message_id": "uuid"}` | Regeneration process initiated |
| `regeneration_complete` | `{"original_id": "uuid", "new_message": {...}}` | New message ready |

**Example Response (new_message):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "content": "Here are some options with chicken and rice...",
  "role": "assistant",
  "timestamp": "2026-06-07T10:30:00Z",
  "suggestions": [
    {"recipe_id": "123", "name": "Chicken Fried Rice", "match_score": 0.95}
  ]
}
```

---

### calendar:* — Calendar Operations

Real-time calendar updates for meal planning.

**Topic Pattern:** `calendar:<account_id>`

#### Incoming Events

| Event | Payload | Description |
|-------|---------|-------------|
| `subscribe` | `{"date_range": {"start": "YYYY-MM-DD", "end": "YYYY-MM-DD"}}` | Subscribe to calendar updates in date range |
| `unsubscribe` | `{"date_range": {...}}` | Unsubscribe from date range updates |
| `refresh` | `{}` | Request full calendar refresh |

**Example Payload (subscribe):**
```json
{
  "date_range": {
    "start": "2026-06-01",
    "end": "2026-06-30"
  }
}
```

#### Outgoing Events

| Event | Payload | Description |
|-------|---------|-------------|
| `slot_updated` | `{"slot": {...}}` | A calendar slot was modified |
| `meal_assigned` | `{"slot": {...}, "recipe": {...}}` | Meal was assigned to a slot |
| `meal_removed` | `{"slot_id": "uuid"}` | Meal was removed from a slot |
| `batch_update` | `{"slots": [...]}` | Multiple slots updated at once |
| `sync_complete` | `{"synced_count": 30}` | Full sync finished |

**Example Response (slot_updated):**
```json
{
  "slot": {
    "id": "550e8400-e29b-41d4-a716-446655440001",
    "date": "2026-06-10",
    "slot": "lunch",
    "is_cooked": false,
    "recipe": {
      "id": "789",
      "name": "Grilled Chicken Salad",
      "calories_per_serving": 350,
      "prep_time_minutes": 15
    },
    "is_favorite": true
  },
  "updated_by": "user"
}
```

---

### planning:* — Weekly Planning

Real-time meal planning workflow coordination.

**Topic Pattern:** `planning:<account_id>`

#### Incoming Events

| Event | Payload | Description |
|-------|---------|-------------|
| `start_planning` | `{"week_start": "YYYY-MM-DD", "constraints": {...}}` | Start a new weekly plan |
| `choose_slot` | `{"slot_id": "uuid", "recipe_id": "uuid"}` | Assign recipe to a slot |
| `remove_slot` | `{"slot_id": "uuid"}` | Remove recipe from a slot |
| `generate_plan` | `{"strategy": "balanced|quick|varied"}` | Trigger AI plan generation |
| `accept_plan` | `{"plan_id": "uuid"}` | Accept generated plan |
| `cancel_planning` | `{}` | Cancel current planning session |

**Example Payload (start_planning):**
```json
{
  "week_start": "2026-06-09",
  "constraints": {
    "meals_per_day": 3,
    "max_prep_time": 60,
    "dietary_restrictions": ["vegetarian"],
    "favorite_recipe_ids": ["123", "456"]
  }
}
```

#### Outgoing Events

| Event | Payload | Description |
|-------|---------|-------------|
| `plan_started` | `{"plan_id": "uuid", "week_start": "YYYY-MM-DD"}` | Planning session started |
| `plan_generated` | `{"plan_id": "uuid", "slots": [...], "confidence": 0.92}` | AI plan is ready |
| `slot_chosen` | `{"slot_id": "uuid", "recipe": {...}}` | User confirmed a slot choice |
| `slot_removed` | `{"slot_id": "uuid"}` | Slot was cleared |
| `plan_conflict` | `{"slot_id": "uuid", "conflicts": [...], "suggestions": [...]}` | Conflict detected |
| `plan_saved` | `{"plan_id": "uuid", "saved_count": 21}` | Plan committed to calendar |
| `planning_error` | `{"code": "string", "message": "string"}` | Error during planning |

**Example Response (plan_generated):**
```json
{
  "plan_id": "550e8400-e29b-41d4-a716-446655440002",
  "slots": [
    {
      "date": "2026-06-09",
      "slot": "breakfast",
      "recipe": {
        "id": "101",
        "name": "Oatmeal with Berries",
        "calories_per_serving": 280
      },
      "confidence": 0.95
    }
  ],
  "confidence": 0.92,
  "missing_meals": 2
}
```

---

### planning_agent:* — Culinary Agent Planning Session (spec #93)

Topic: `planning_agent:<household_id>` (the current membership's `account_id`). Lives
beside the legacy `planning:*` flow; it is a thin adapter over
`MealPlannerApi.PlanningAgent.Session`. The Household always comes from the
membership, never from a payload.

One Planning Session per Household: while one is active, any other Member's
`start_session` is refused with `session_already_active` (also when its range overlaps
the active one; `overlapping_range` is only the store's last-resort guard). The session ends when it is
cancelled or when its Member's socket leaves (grace and recovery come later).

#### Incoming Events

| Event | Payload | Reply |
|-------|---------|-------|
| `start_session` | `{range_from, range_to, slots?}` — ISO dates, at most 31 days of unplanned days; `slots` from `breakfast`, `lunch`, `snack`, `dinner` (default `lunch`, `dinner`) | `{session_id}` or `{reason}`: `session_already_active`, `range_already_planned`, `overlapping_range`, `invalid_range`, `invalid_slots`, `subscription_required`, `spend_caps_unconfigured`, `pricing_unconfigured`, `provider_unconfigured`, `internal_error` |
| `give_consent` | `{}` — explicit consent before the first external AI use | `ok` |
| `send_message` | `{text}` — a non-blank string of at most 4,000 bytes | `ok`, or `{reason}`: `invalid_message` (missing, non-string or blank `text`), `message_too_long`, `consent_required`, `busy`, `authorization_required` (a limit was reached), `no_active_session`, `internal_error` |
| `authorize_continuation` | `{}` — only the session's Member, after `limit_reached` | `ok` (the request resumes with that limit extended) or `{reason}`: `forbidden`, `no_limit_reached`, `no_active_session` |
| `cancel_session` | `{}` — the session's Member or the Household Owner | `{status: "cancelled"}` or `{reason}`: `forbidden`, `no_active_session` |
| any other event | — | `{reason}`: `invalid_payload` |

#### Outgoing Events

Every event is pushed as `agent_event` with `type` and `session_id`:

| `type` | Payload | Meaning |
|--------|---------|---------|
| `progress` | `{step}` — `thinking`, `searching_recipes`, `reading_plan` (also for `reuse_plan`), `reading_pantry`, `looking_up_prices`, `reading_recipe`, `drafting_recipe`, `running_optimizer`, `validating_proposal`; `retrying` with `{call, attempt}` (`call`: `model`, `read`, `solver`); `tool_finished` with `{tool, outcome}` | The agent is working (no raw reasoning or tool output: events pass a field allowlist) |
| `assistant_message` | `{text}` | Agent reply |
| `question` | `{text}` | The agent asks one question; the turn ended |
| `proposal` | `{proposal_id, status, meals: [{date, slot, recipe_id, name}], purchase, consumed_cost, budget, deviations}` | A Proposal validated by code; `status` is code-owned (`valid` or `requires_approval`). See "Proposal Purchase" below |
| `recipe_draft` | `{recipe_id, name, origin, draft: true, servings, slots, ingredients: [{ingredient, quantity_milli, unit}], steps, nutrition, cost}` | The agent built a Recipe Draft from catalog Ingredients. `origin` is `ai_created` (disclose as AI-made, possibly imperfect) or `user_created` (a dictated recipe). See "Recipe Drafts" below |
| `optimizer_failed` | `{reason}` | The optimizer failed; no fallback plan is produced |
| `consent_required` | `{}` | Consent must be given before the agent can call the AI provider |
| `limit_reached` | `{limit, requires_authorization: true}` — `iterations`, `no_progress` or `time` | Execution stopped: 10 iterations per Planning Session (new messages do not reset them), 3 consecutive attempts without new evidence, or 5 minutes per request. Nothing runs until the Member sends `authorize_continuation` |
| `agent_unavailable` | `{reason}` | The AI provider cannot be used now: `provider_unavailable` / `provider_timeout` after up to 5 retries, or at once for `provider_unauthorized`, `provider_rejected_request`, `provider_conflict`, `spend_cap_reached`, `token_cap_reached` |
| `turn_completed` | `{}` | The agent finished answering |
| `run_finished` | `{outcome}` — `complete`, `partial`, `failure`, `cancelled`, `unknown` | Exactly one per request or authorized continuation; `partial` means stopped by a limit, `unknown` that the run crashed |
| `session_cancelled` / `session_ended` | `{}` | The Planning Session is over |

#### Proposal Purchase

Every `proposal` carries its Purchase: the packages the Household must buy,
computed by code from the Proposal's meals net of the Projected Pantry
(Pantry minus stock committed to not-yet-cooked Planned Meals, inside or
outside the range). Needs are aggregated once per ingredient and unit, then
rounded up to whole packages of the stored Product with the lowest package
total.

```json
{
  "purchase": {
    "lines": [{"ingredient": "…", "quantity_milli": 250000, "unit": "g",
               "packages": 1, "total_cents": 800, "product": "…", "brand": "…",
               "presentation": {"quantity_milli": 500000, "unit": "g"},
               "supermarket": "…", "price_cents": 800, "currency": "ARS",
               "observed_at": "2026-10-13T09:30:00.000000Z"}],
    "missing_prices": [{"ingredient": "…", "quantity_milli": 2000, "unit": "g",
                        "reason": "no_stored_price"}],
    "total_cents": 800, "currency": "ARS", "complete": false
  },
  "consumed_cost": {"total_cents": 480, "currency": "ARS", "complete": false,
                    "missing_prices": []},
  "budget": {"budget_cents": 1500, "purchase_total_cents": 800,
             "within_budget": null, "uncertain": true},
  "deviations": []
}
```

- The budget is compared against `purchase.total_cents`, never the consumed
  cost. Overspend is a `{"type": "budget", budget_cents, total_cents,
  difference_cents}` Deviation and makes the status `requires_approval`.
- Missing prices (`no_stored_price`, `no_matching_presentation`,
  `currency_mismatch`) are never zero: they are left out of the total, which
  becomes a lower bound (`complete: false`, `uncertain: true`); then
  `within_budget` is `null` unless the lower bound already overspends.
- `budget_cents` is `null` when the Household has no budget set.

#### Recipe Drafts

A Recipe Draft exists only in the Planning Session's Workspace: it is never
saved by the agent and disappears when the session ends unconfirmed. Its
Ingredients are catalog Ingredients only (an unknown one rejects the Draft),
and its nutrition and cost are computed by code:

```json
{
  "nutrition": {"per_serving": {"calories": 380, "protein_g": 13.5,
                                "carbs_g": 76.0, "fat_g": 1.8},
                "complete": true, "missing": []},
  "cost": {"total_cents": 1000, "per_serving_cents": 500, "currency": "ARS",
           "complete": true, "missing_prices": []}
}
```

- A nutrient is `null` unless every Ingredient has it per 100 g or ml;
  `missing` names the Ingredients without data ("partial nutrition").
- `cost` is the consumed-ingredient cost at stored prices; missing prices are
  named and left out of the total (`complete: false`), never zero.

Paid execution requires `OPENAI_API_KEY`, `PLANNING_AGENT_SPEND_CAP_MICROS`,
`PLANNING_AGENT_TOKEN_CAP`, `OPENAI_INPUT_PRICE_MICROS_PER_MTOK` and
`OPENAI_OUTPUT_PRICE_MICROS_PER_MTOK`; without them `start_session` replies
`spend_caps_unconfigured` (or `pricing_unconfigured` / `provider_unconfigured`).
The spend and token caps apply per Planning Session and are never extended by
`authorize_continuation`.

Per-call bounds: each model attempt 60 s (up to 5 transient retries), each
solve 120 s (no retry; a timeout is inconclusive), each recipe search 30 s (up
to 2 retries), with increasing backoff and every deadline shortened by the
request's remaining 5 minutes. No retry starts while the Member is absent.

---

### cooking:* — Cooking Mode

Real-time cooking guidance and timer synchronization.

**Topic Pattern:** `cooking:<recipe_id>`

#### Incoming Events

| Event | Payload | Description |
|-------|---------|-------------|
| `start_cooking` | `{"recipe_id": "uuid", "servings": number}` | Start cooking mode for a recipe |
| `step_complete` | `{"step_index": number, "notes": "string"}` | Mark a step as completed |
| `timer_start` | `{"duration_seconds": number, "label": "string"}` | Start a cooking timer |
| `timer_pause` | `{"timer_id": "uuid"}` | Pause a running timer |
| `timer_resume` | `{"timer_id": "uuid"}` | Resume a paused timer |
| `timer_cancel` | `{"timer_id": "uuid"}` | Cancel a timer |
| `update_servings` | `{"servings": number}` | Update serving size |
| `end_cooking` | `{"rating": number, "notes": "string"}` | End cooking session |

**Example Payload (start_cooking):**
```json
{
  "recipe_id": "789",
  "servings": 4
}
```

#### Outgoing Events

| Event | Payload | Description |
|-------|---------|-------------|
| `cooking_started` | `{"session_id": "uuid", "recipe": {...}, "steps": [...]}` | Cooking session initialized |
| `step_update` | `{"current_step": number, "total_steps": number}` | Current step changed |
| `step_complete` | `{"step_index": number, "next_step": {...}}` | Step marked complete |
| `timer_tick` | `{"timer_id": "uuid", "remaining_seconds": number}` | Timer countdown update |
| `timer_done` | `{"timer_id": "uuid", "label": "string"}` | Timer finished |
| `scaled_ingredients` | `{"original_servings": number, "new_servings": number, "ingredients": [...]}` | Ingredients rescaled |
| `cooking_complete` | `{"session_id": "uuid", "duration_minutes": number}` | Cooking session ended |

**Example Response (timer_done):**
```json
{
  "timer_id": "550e8400-e29b-41d4-a716-446655440003",
  "label": "Boil pasta",
  "remaining_seconds": 0,
  "next_action": "drain_pasta"
}
```

---

## Reconnection Strategy

Implement exponential backoff with jitter for WebSocket reconnection:

```javascript
class MealPlannerSocket {
  constructor(url, params) {
    this.url = url;
    this.params = params;
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 10;
    this.socket = null;
  }

  connect() {
    this.socket = new Socket(this.url, { params: this.params });

    this.socket.onError(() => this.handleError());
    this.socket.onClose(() => this.handleClose());

    this.socket.connect();
  }

  handleError() {
    console.error("Socket connection error");
  }

  handleClose() {
    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      const delay = this.calculateBackoff();
      console.log(`Reconnecting in ${delay}ms...`);

      setTimeout(() => {
        this.reconnectAttempts++;
        this.refreshToken().then(token => {
          this.params.token = token;
          this.connect();
        });
      }, delay);
    } else {
      console.error("Max reconnection attempts reached");
    }
  }

  calculateBackoff() {
    // Exponential backoff with jitter: base * 2^attempt + random(0-1000)
    const base = 1000;
    const maxDelay = 30000;
    const exponentialDelay = Math.min(base * Math.pow(2, this.reconnectAttempts), maxDelay);
    const jitter = Math.random() * 1000;
    return exponentialDelay + jitter;
  }

  async refreshToken() {
    // Fetch a new JWT from your auth endpoint
    const response = await fetch("/api/auth/refresh", {
      method: "POST",
      credentials: "include"
    });
    const { token } = await response.json();
    return token;
  }
}
```

---

## Error Handling

| Error Code | HTTP Status | Description | Recovery Action |
|-----------|-------------|-------------|----------------|
| `auth_required` | 401 | No valid token provided | Redirect to login |
| `token_expired` | 401 | JWT has expired | Refresh token, reconnect |
| `channel_not_found` | 404 | Invalid topic pattern | Verify topic format |
| `rate_limited` | 429 | Too many requests | Apply backoff, retry |
| `server_error` | 500 | Internal server error | Log error, notify user |
| `channel_closed` | - | Server closed the channel | Auto-reconnect |

---

## Best Practices

1. **Subscribe lazily**: Only join channels when needed, leave when done
2. **Handle disconnections**: Implement reconnection with exponential backoff
3. **Batch updates**: For bulk operations, use batch events to reduce overhead
4. **Timeout handling**: Set reasonable timeouts for requests expecting responses
5. **Presence tracking**: Use Phoenix Presence for showing active users in cooking mode