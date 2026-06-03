# Proposal: v2 Planning with Real-time Streaming + Recipe Pricing

## 1. Problem Statement

The current meal planning chat (`POST /planning/chat`) is synchronous: the user waits, the server generates, responds when done. For v2, the user wants:

1. **Live price-aware plans** — OR-Tools generates plans using daily-scraped ingredient prices from a Go scraper
2. **Real-time feedback** — slots appear in the UI as OR-Tools resolves them (streaming)
3. **Macro-aware generation** — the AI knows the user's budget, protein goals, and food preferences before optimizing
4. **Recipe modification in-chat** — after seeing a proposal, the user can ask "change Tuesday's pasta for something gluten-free" and the server updates the proposal in-place
5. **Structured extraction** — the AI converts the final plan into a shopping cart (JSON) and weekly meal plan (JSON) ready to persist

## 2. Constraints / Non-goals

**Constraints:**
- Keep Elixir/Phoenix as the orchestration layer
- Keep Python + OR-Tools for optimization
- Keep Go scraper as-is (external, exposes HTTP API)
- Elixir puxea precios del Go via HTTP durante price sync nocturno
- Phoenix Channels for streaming (not SSE)
- Existing REST API stays backward-compatible (v1 still works)

**Non-goals:**
- Replacing the current `POST /planning/chat` endpoint (kept for v1 clients)
- Multi-account concurrent planning in one channel (one lobby per account)
- Voice input processing (handled externally before reaching this layer)

## 3. Scope

**In scope:**
- `PlanningChannel` (Phoenix Channels) — join, start, chat, confirm
- `GenerationServer` (GenServer/OTP) — orchestrates the full lifecycle
- HTTP client in Elixir → Python endpoints (replaces Port/stdio)
- Python: `POST /api/v1/optimize-menu` + `POST /api/v1/extract-shopping-list`
- `ingredient_prices` + `recipe_prices` tables
- Real-time broadcasts: `slot_progress`, `proposal_ready`, `proposal_update`, `error`
- In-channel recipe modification (partial regeneration)
- Price-aware constraint payload to OR-Tools

**Out of scope:**
- Go scraper (already exists, exposes HTTP API that Elixir calls)
- React Native frontend (separate repo)
- Voice transcription (handled before reaching this layer)
- Persistent chat history (future)

## 4. API Design (Phoenix Channel)

```
Channel topic: "planning:lobby"  (one per account)

Client → Server events:
  handle_in("start", payload)     → starts generation
  handle_in("chat", payload)      → modifies / follows up on proposal
  handle_in("confirm", payload)   → persists plan to DB
  handle_in("reject", payload)    → discards and leaves

Server → Client events (broadcasts):
  "slot_progress"    → %{slot: "tuesday_lunch", recipe: {...}, price_cents: 3200}
  "proposal_ready"   → %{proposal_id, proposal_json, shopping_items_json, total_price_cents}
  "proposal_update"  → %{proposal_id, updated_slots: [...]}
  "error"            → %{reason: "budget_exceeded"}
  "confirmed"        → %{scheduled_meals_count, shopping_items_count}
```

### HTTP endpoints (Python, for OR-Tools + LLM)

```
POST /api/v1/optimize-menu
Body: {
  slots: [{date, slot, available_recipe_ids, max_price_cents}],
  budget_cents: 50000,
  protein_g_per_meal: 30,
  exclusions: ["gluten", "dairy"],
  preferences: ["mediterranean", "high_protein"]
}
Response: {slots: [{date, slot, recipe_id, price_cents}]}

POST /api/v1/extract-shopping-list
Body: {
  recipes: [{recipe_id, name, servings, ingredients: [{name, quantity, unit}]}],
  available_supermarkets: ["disco", "carrefour", "changomas"]
}
Response: {
  shopping_items: [{ingredient, quantity, unit, estimated_price_cents, supermarket}],
  recipe_prices: [{recipe_id, total_price_cents, per_serving_cents}]
}
```

## 5. Data Model Changes

### New tables

**`ingredient_prices`** — written daily by Go scraper:
```
ingredient_id (FK, not null)
supermarket_id (string, not null)
price_per_unit_cents (integer, not null)
unit (string, e.g. "kg", "unit", "l")
scraped_at (utc_datetime)
```

**`recipe_prices`** — precomputed from ingredient_prices, refreshed daily:
```
recipe_id (FK, not null)
price_per_serving_cents (integer, not null)
last_calculated_at (utc_datetime)
```

### Existing tables used

| Table | Usage |
|-------|-------|
| `users` | identity resolution |
| `accounts` | account context |
| `scheduled_meals` | persisted weekly plan |
| `planning_proposals` | proposal storage |
| `planning_generation_runs` | generation metadata |
| `shopping_items` | shopping cart (written from extracted JSON) |
| `scheduled_meals` | weekly plan (written from proposal JSON) |

## 6. Architecture

```
React Native (Frontend)
  └── Phoenix Channel "planning:lobby"

Elixir/Phoenix
  ├── PlanningChannel          ← receives events, broadcasts results
  └── GenerationServer (GenServer)
        ├── Identity resolution
        ├── Fetches ingredient_prices from DB
        ├── Builds constraint payload (budget, macros, exclusions)
        └── Orchestrates HTTP calls

Python (FastAPI/Flask)
  ├── POST /api/v1/optimize-menu       → OR-Tools
  └── POST /api/v1/extract-shopping-list → LLM structured output

PostgreSQL
  └── ingredient_prices + recipe_prices (written by Elixir via mix price_sync.run)
```

## 7. Open Questions

1. **Go → Elixir communication**: Elixir runs `mix price_sync.run` nightly. This Mix task:
   a. Lists all ingredients from the DB
   b. For each ingredient, calls `GoScraperClient.get_price(ingredient_name)` → HTTP GET to Go API
   c. Upserts results to `ingredient_prices`
   d. Recomputes `recipe_prices`
   
   Go scraper does NOT write to DB. It just serves an HTTP endpoint `/price?ingredient=...` returning prices per supermarket. Elixir owns the DB.
2. **Protein/macro constraints**: Where does the user's protein goal (g per meal) come from? A user profile field, or passed per-request?
3. **Supermarket selection**: User picks preferred supermarket(s) in their profile or per-session?
4. **Recipe modification scope**: "Change Tuesday's pasta" — does OR-Tools re-optimize just that slot, or regenerate adjacent slots too?
5. **Concurrency**: Can the same account have multiple planning sessions? (Recommended: no, lobby is exclusive)
6. **Timeout**: If OR-Tools takes > 30s, what happens? Cancel and broadcast error?

## 8. Success Criteria

- User opens Vista 2 → channel join succeeds
- User sends "start" with constraints → first `slot_progress` arrives within 2s, remaining slots stream progressively
- All slots resolved → `proposal_ready` arrives with full JSON
- User says "change X for Y" → `proposal_update` arrives with modified slot
- User confirms → `confirmed` arrives, DB contains weekly meals + shopping items
- Backend works with mocked Go scraper (prices pre-seeded)