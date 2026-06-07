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