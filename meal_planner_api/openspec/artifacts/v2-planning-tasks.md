# Tasks: v2 Planning Streaming + Recipe Pricing

## How to read this document

Tasks are ordered in dependency order. Implement in sequence.
Status: `pending` → `in_progress` → `completed`

---

## Phase A — Data Layer (no external deps)

### A1. Migrations

- [ ] **A1.1** `20250603000000_create_ingredient_prices.exs` — table with unique index on `(ingredient_id, supermarket_id)`
- [ ] **A1.2** `20250603000001_create_recipe_prices.exs` — table with unique index on `recipe_id`
- [ ] **A1.3** `20250603000002_create_user_preferences.exs` — table with unique index on `user_id`

### A2. Schemas

- [ ] **A2.1** `persistence/shopping/ingredient_price.ex` — Ecto schema for `ingredient_prices`
- [ ] **A2.2** `persistence/shopping/recipe_price.ex` — Ecto schema for `recipe_prices`
- [ ] **A2.3** `persistence/accounts/user_preference.ex` — Ecto schema for `user_preferences` (protein_g_per_meal, default_exclusions)

### A3. Data Repos

- [ ] **A3.1** `data/price_repo.ex` — `latest_prices/1`, `best_price_per_ingredient/1`, `upsert_prices/1`, `get_recipe_price/1`, `compute_all_recipe_prices/0`
- [ ] **A3.2** `data/user_preference_repo.ex` — `get/1`, `upsert/2` for user_preferences
- [ ] **A3.3** `test/data/price_repo_test.exs` — 6 tests for PriceRepo functions (RED first)

---

## Phase B — External Integrations

### B1. GoScraperClient

- [ ] **B1.1** `integrations/go_scraper_client.ex` — HTTP client with `get_price(ingredient_name)`, uses `Tesla`
- [ ] **B1.2** `integrations/go_scraper_client/mock.ex` — Returns static realistic prices for dev/test
- [ ] **B1.3** `test/integrations/go_scraper_client_test.exs` — tests with mock

### B2. PythonClient

- [ ] **B2.1** `integrations/python_client.ex` — HTTP client with:
  - `optimize_menu(slots, constraints) :: {:ok, result} | {:error, :timeout | :unreachable}`
  - `optimize_slot(slot, constraints) :: {:ok, result} | {:error, term()}`
  - `extract_shopping_list(recipes) :: {:ok, result} | {:error, term()}`
  - Uses `Req`, 30s timeout, JSON encode/decode

- [ ] **B2.2** `integrations/python_client/mock.ex` — Mock that:
  - `optimize_menu` sends `slot_progress` events via `send_after` (one per slot, 200ms delay)
  - `extract_shopping_list` returns realistic shopping items
  - Used in dev + test environments

- [ ] **B2.3** `test/integrations/python_client_test.exs` — 4 tests (RED first)

### B3. Price Sync Mix Task

- [ ] **B3.1** `lib/mix/tasks/price_sync.run.ex`:
  - Lists all ingredients
  - Calls `GoScraperClient.get_price/1` per ingredient
  - Calls `PriceRepo.upsert_prices/1`
  - Calls `PriceRepo.compute_all_recipe_prices/0`
  - Logs summary: N prices updated, M recipes recomputed
- [ ] **B3.2** `test/mix/tasks/price_sync_run_test.exs` — tests mix task output

---

## Phase C — Services

### C1. PriceService

- [ ] **C1.1** `services/price_service.ex`:
  - `fetch_ingredient_prices(ingredient_ids) :: map()` — calls PriceRepo
  - `fetch_recipe_prices(recipe_ids) :: map()` — calls PriceRepo
  - `compute_slot_list_for_optimization(account_id, user_id, date_from, date_to, constraints) :: [slot]`
    — builds the slot list with available_recipe_ids filtered by exclusions
- [ ] **C1.2** `test/services/price_service_test.exs` — 5 tests (RED first)

### C2. GenerationService (stateless orchestrator)

- [ ] **C2.1** `services/generation_service.ex` — pure functions, used by GenerationServer:
  - `build_constraints(user, payload) :: constraints` — merges profile defaults + payload overrides
  - `resolve_constraints(constraints) :: resolved_constraints` — fills in missing from profile
  - `parse_modification(message) :: {:ok, %{date, slot, new_constraints}} | {:error, :invalid_modification}`
  - `build_proposal_json(slots) :: map()` — serializes slots into the proposal structure
  - `parse_shopping_items(json) :: [item]` — extracts shopping items from extracted JSON

---

## Phase D — GenerationServer (OTP)

### D1. Module + Supervisor

- [ ] **D1.1** `generation/supervisor.ex`:
  - `DynamicSupervisor` named `MealPlannerApi.GenerationSupervisor`
  - Starts/stops `GenerationServer` per account

- [ ] **D1.2** `generation/generation_server.ex`:
  - Registry-based naming via `MealPlannerApi.Registry.Generations`
  - States: `:idle`, `:running`, `:completed`, `:error`
  - `start_generation/4` — validates not already running, spawns GenServer
  - `chat/3` — partial regeneration
  - `confirm/2` — persist to DB
  - `reject/2` — cleanup

- [ ] **D1.3** `test/generation/generation_server_test.exs` — 8 tests (RED first)

---

## Phase E — Phoenix Channel

### E1. PlanningChannel

- [ ] **E1.1** `web/channels/planning_channel.ex`:
  - `join("planning:lobby", _, socket)` — validates JWT, assigns user to socket
  - `handle_in("start", %{"constraints" => c}, socket)` — calls `GenerationServer.start_generation`
  - `handle_in("chat", %{"message" => m, "proposal_id" => p}, socket)` — calls `GenerationServer.chat`
  - `handle_in("confirm", %{"proposal_id" => p}, socket)` — calls `GenerationServer.confirm`
  - `handle_in("reject", %{"proposal_id" => p}, socket)` — calls `GenerationServer.reject`
  - Handles broadcast delivery from GenerationServer via `handle_info`

- [ ] **E1.2** `test/channels/planning_channel_test.exs` — 6 tests (RED first)

### E2. Router

- [ ] **E2.1** Add `socket "/socket", MealPlannerApiWeb.UserSocket` to router if not present
- [ ] **E2.2** Add channel route: `socket "/phoenix/live_view", Phoenix.LiveView.Socket` (if LiveView used elsewhere)

---

## Phase F — End-to-end Wiring

### F1. User Preferences in AccountService

- [ ] **F1.1** Extend `AccountService` with:
  - `get_user_preferences(user_id) :: UserPreference.t() | nil`
  - `upsert_user_preferences(user_id, attrs) :: {:ok, UserPreference.t()}`

### F2. Confirm flow in GenerationServer

- [ ] **F2.1** `confirm/2` function:
  - Reads `proposal_json` from state
  - Calls `PlanningRepo.schedule_meal/1` per slot
  - Calls `ShoppingService.create_items_from_json/1` (or new method)
  - Updates proposal status → `:confirmed`

### F3. Config

- [ ] **F3.1** Add to `config/runtime.exs`:
  ```elixir
  config :meal_planner_api,
    python_api_url: System.get_env("PYTHON_API_URL", "http://localhost:8001"),
    optimize_timeout_ms: 30_000,
    go_scraper_url: System.get_env("GO_SCRAPER_URL", "http://localhost:8080")
  ```
- [ ] **F3.2** Add to `config/dev.exs`:
  ```elixir
  config :meal_planner_api,
    python_api_url: "http://localhost:8001",
    go_scraper_url: "http://localhost:8080",
    python_client_mode: :mock  # or :real
  ```

---

## Phase G — Python Endpoints (separate repo or local)

> These are in the Python service, not in meal_planner_api. Listed here for completeness.

- [ ] **G1** `POST /api/v1/optimize-menu` — OR-Tools with price-aware constraint solving
- [ ] **G2** `POST /api/v1/optimize-slot` — single slot re-optimization
- [ ] **G3** `POST /api/v1/extract-shopping-list` — LLM structured output (Gemini)

---

## Task Count Summary

| Phase | Tasks | LOC (est.) |
|-------|-------|-----------|
| A — Data | 7 | ~250 |
| B — Integrations | 6 | ~250 |
| C — Services | 5 | ~200 |
| D — GenServer | 3 | ~350 |
| E — Channel | 3 | ~150 |
| F — Wiring | 4 | ~100 |
| **Total** | **28** | **~1300** |

**Estimated total: ~1250 LOC** across 14 new files + tests.

---

## Test Coverage Target

- `GenerationServer`: 8 tests
- `PlanningChannel`: 6 tests
- `PriceRepo`: 6 tests
- `UserPreferenceRepo`: 3 tests
- `PriceService`: 5 tests
- `PythonClient`: 4 tests
- `GoScraperClient`: 3 tests
- Mix task: 2 tests

**Total new tests: 37**

---

## Milestones

| Milestone | Contains | When complete |
|-----------|----------|---------------|
| M1 — Data Layer | A1, A2, A3, C1 | Phase A + Phase C1 |
| M2 — Integrations | B1, B2, B3 | Phase B |
| M3 — Core Engine | C2, D1, D2 | Phase C2 + Phase D |
| M4 — Channel + Wiring | E1, E2, F1, F2, F3 | Phase E + Phase F |
| M5 — Full Flow | All green tests, manual smoke test | Post-F |

**Recommendation:** Deliver Milestone M1 first (data layer is foundation). Each milestone is independently testable.