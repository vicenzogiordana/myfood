# Spec: v2 Planning Streaming + Recipe Pricing

## 1. Overview

Real-time meal planning via Phoenix Channels. User joins `planning:lobby`, sends constraints (budget, protein, exclusions, preferences), OR-Tools generates a price-aware weekly plan streamed slot-by-slot, the user can modify individual slots in-chat, and on confirmation the system persists both the weekly meals and a structured shopping cart.

**Not in scope:** Go scraper (external), React Native frontend (separate repo), voice transcription (handled upstream).

---

## 2. Channel Protocol

**Topic:** `"planning:lobby"` — one per account. If a generation is already running, subsequent `start` events return an error.

### Client → Server events

| Event | Payload | Description |
|-------|---------|-------------|
| `"start"` | `{message, constraints}` | Starts a new generation. `constraints` overrides profile defaults. |
| `"chat"` | `{message, context}` | In-chat follow-up (e.g. "change Tuesday lunch for something gluten-free"). Server has `proposal_id` in its state. |
| `"confirm"` | `{proposal_id}` | Persists the proposal to DB. |
| `"reject"` | `{proposal_id}` | Discards the proposal. |
| `"leave"` | `{}` | User leaves the channel gracefully. |

### Server → Client events (broadcasts)

| Event | Payload | Description |
|-------|---------|-------------|
| `"generation_started"` | `{run_id}` | Generation kicked off. |
| `"slot_progress"` | `{slot_key: "YYYY-MM-DD_slot", recipe_id, recipe_name, price_cents}` | OR-Tools resolved one slot. Front renders it immediately. |
| `"proposal_ready"` | `{proposal_id, proposal_json, shopping_items_json, total_price_cents}` | All slots resolved. Proposal saved to DB with `status: :pending`. |
| `"proposal_update"` | `{slot_key: "YYYY-MM-DD_slot", recipe}` | A single slot was modified. |
| `"error"` | `{reason, code}` | Generation failed at some step. |
| `"confirmed"` | `{scheduled_meals_count, shopping_items_count}` | Proposal confirmed and persisted. |

### `constraints` object (in `"start"` payload)

```json
{
  "budget_cents": 50000,
  "protein_g_per_meal": 30,
  "exclusions": ["gluten", "dairy", "nuts"],
  "preferences": ["mediterranean", "high_protein"],
  "supermarkets": ["disco", "carrefour"],
  "date_from": "2025-06-02",
  "date_to": "2025-06-08"
}
```

All fields are **optional**. If absent, values come from the user's profile.

---

## 3. Data Flow

```
1. Channel receives "start" + constraints
        │
        ▼
2. GenerationServer.start(constraints)
        │
        ├─ Identity resolution (account_id, user_id)
        │
        ├─ Fetch user profile (protein_g_per_meal, default_exclusions, etc.)
        │          Merge with constraints (payload overrides profile)
        │
        ├─ Fetch ingredient_prices from DB (last 24h)
        │
        ├─ Build slot list with available recipe_ids (filtered by exclusions + suitable_for_slots)
        │
        ├─ HTTP POST /api/v1/optimize-menu
        │       Python/OR-Tools resolves all slots
        │       Per slot: broadcast "slot_progress"
        │
        ├─ Build proposal_json (weekly plan structure)
        │
        ├─ HTTP POST /api/v1/extract-shopping-list
        │       Python/LLM converts recipe text → shopping_items_json
        │
        ├─ Broadcast "proposal_ready"
        │       {proposal_id, proposal_json, shopping_items_json}
        │
        └─ Store proposal + generation_run in DB (status: :pending)
```

---

## 4. Slot Modification ("chat" event)

User says: *"cambiá la pasta del martes por algo sin TACC"*

```
1. Channel receives "chat" + {message: "...", proposal_id: "..."}
        │
        ▼
2. GenerationServer.chat(message, proposal_id)
        │
        ├─ Parse instruction (extract: slot_key, new_constraint)
        │        "tuesday lunch" → date=2025-06-03, slot="lunch"
        │        "sin TACC" → exclusions=["gluten"]
        │
        ├─ Fetch ingredient_prices from DB
        │
        ├─ Fetch that slot's current recipe_id and neighbors (same day)
        │
        ├─ HTTP POST /api/v1/optimize-slot
        │       Body: {date, slot, available_recipe_ids, constraints, exclude_current: true}
        │       Python/OR-Tools returns the new recipe for that slot only
        │
        ├─ Update proposal_json in-memory (server state)
        │
        └─ Broadcast "proposal_update" {slot_key: "YYYY-MM-DD_slot", recipe}
```

---

## 5. Confirmation

```
1. Channel receives "confirm" + {proposal_id}
        │
        ▼
2. GenerationServer.confirm(proposal_id)
        │
        ├─ Parse scheduled_meals from proposal_json
        │
        ├─ Loop: PlanningRepo.schedule_meal(meal_attrs) for each slot
        │
        ├─ Parse shopping_items_json
        │
        ├─ Loop: ShoppingRepo.create_item(item) for each ingredient
        │
        ├─ Update proposal status → :confirmed
        │
        └─ Broadcast "confirmed" {scheduled_meals_count, shopping_items_count}
```

---

## 6. External Integrations

### 6.1 Elixir → Python (HTTP)

Elixir acts as HTTP client. Python runs as a separate service (FastAPI or Flask).

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/optimize-menu` | POST | Full weekly optimization |
| `/api/v1/optimize-slot` | POST | Single slot re-optimization |
| `/api/v1/extract-shopping-list` | POST | Recipe text → structured JSON |

**Request timeout:** 30s per call. On timeout: broadcast `"error"` with code `timeout`.

**Mock/development:** If Python is unreachable, falls back to `OptimizerFallback` (mock data) so development continues.

### 6.2 Elixir → Go Scraper (nightly script)

A separate Mix task runs nightly (via cron/systemd timer):

```
mix price_sync.run
```

This task:
1. Lists all active ingredients in the DB
2. For each ingredient, calls `GoScraperClient.get_price(ingredient_name)`
3. Writes results to `ingredient_prices`
4. Pre-computes `recipe_prices` from the new prices

**GoScraperClient** is a module that HTTP-calls the Go API. Mock exists for development.

---

## 7. Data Model

### 7.1 New tables

**`ingredient_prices`**
```
id                  uuid PK
ingredient_id       uuid FK → ingredients (not null)
supermarket_id      string not null  ("disco", "carrefour", "changomas")
price_per_unit_cents integer not null
unit                string not null  ("kg", "unit", "l", "g")
scraped_at          utc_datetime
inserted_at         utc_datetime
```
**Unique constraint:** `(ingredient_id, supermarket_id)`

**`recipe_prices`**
```
id                  uuid PK
recipe_id           uuid FK → recipes (not null)
price_per_serving_cents integer not null
last_calculated_at  utc_datetime
```
**Unique constraint:** `recipe_id`

### 7.2 Extended existing tables

**`accounts`** or **`user_preferences`** gains:
- `protein_g_per_meal` (integer, nullable) — default grams of protein per meal
- `default_exclusions` (text array, nullable) — ["gluten", "dairy"]

### 7.3 Existing tables

| Table | Role |
|-------|------|
| `scheduled_meals` | Final weekly plan (written on confirm) |
| `planning_proposals` | Proposal JSON (created on proposal_ready, updated on confirm) |
| `planning_generation_runs` | Generation metadata |
| `shopping_items` | Ingredients (written from extract-shopping-list JSON on confirm) |

---

## 8. GenerationServer (OTP GenServer)

**Name:** `GenerationServer` (via `Registry` — one per account)

**State:**
```elixir
%{
  account_id: pos_integer(),
  user_id: pos_integer(),
  proposal_id: String.t() | nil,
  proposal_json: map() | nil,
  shopping_items_json: map() | nil,
  generation_status: :idle | :running | :completed | :error,
  constraints: map()
}
```

**Interface functions:**
- `start(account_id, user_id, constraints) :: {:ok, run_id} | {:error, :already_running}`
- `chat(proposal_id, message) :: {:ok, %{slot_key, recipe}} | {:error, reason}`
- `confirm(proposal_id) :: {:ok, %{scheduled_meals_count, shopping_items_count}}`
- `reject(proposal_id) :: :ok`

---

## 9. Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `python_api_url` | `"http://localhost:8001"` | Python FastAPI base URL |
| `optimize_timeout_ms` | `30_000` | HTTP timeout for Python calls |
| `price_sync_schedule` | `"0 4 * * *"` | Cron for nightly price sync |
| `channel_presence_ttl` | `86_400` | Presence TTL (24h) |

---

## 10. Error Handling

| Scenario | Action |
|----------|--------|
| Python unreachable | Use `PythonClient.Mock`, broadcast `"proposal_ready"` with mock data |
| OR-Tools returns no valid plan | Broadcast `"error"` with `code: "no_valid_plan"` |
| OR-Tools timeout (>30s) | Cancel request, broadcast `"error"` with `code: "timeout"` |
| Ingredient with no price in DB | Keep recipe in optimization using its stored fallback price (scraper never deletes prices; first scrape records price and it persists) |
| User not in channel when proposal_ready | Store proposal in DB with `status: :pending`. On re-join, channel checks for pending proposals and re-delivers |
| Concurrent start attempted | Return `{:error, :already_running}` via channel push |
| Invalid slot modification | Broadcast `"error"` with `code: "invalid_slot"` |
| Go scraper unreachable during price sync | Skip that ingredient, log warning, continue with others. Final log: N failed, M succeeded |

---

## 11. Acceptance Criteria

- [ ] `mix price_sync.run` fetches prices from Go API and writes `ingredient_prices`
- [ ] `recipe_prices` are pre-computed from latest `ingredient_prices`
- [ ] Channel joins successfully with JWT auth
- [ ] `"start"` with constraints produces `slot_progress` broadcasts per slot
- [ ] All slots resolve → `proposal_ready` with full JSON
- [ ] `"chat"` with slot modification → `proposal_update` for that slot only
- [ ] `"confirm"` persists `scheduled_meals` + `shopping_items` to DB
- [ ] Fallback to mock data works when Python is down
- [ ] GenerationServer is one-per-account (Registry-based)
- [ ] All new code has unit tests (TDD: RED, GREEN, TRIANGULATE)