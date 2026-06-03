# SDD Tasks: MealPlannerApi — Full Architecture Redo

## Change Summary

Implementation tasks for clean 3-layer architecture with GenServer+Port optimizer, injected ports, and pure data access.

---

## Task Overview

| Phase | Tasks | Est. Lines | Risk |
|---|---|---|---|
| **Phase 1: Ports** | 9 tasks | ~800 | Medium |
| **Phase 2: Repos** | 5 tasks | ~600 | Low |
| **Phase 3: Services** | 6 tasks | ~900 | Medium |
| **Phase 4: Controllers** | 7 tasks | ~500 | Low |
| **Phase 5: Cleanup** | 4 tasks | ~200 | Low |
| **Total** | **31 tasks** | **~3000 lines** | |

> ⚠️ **Review workload warning**: 3000 changed lines exceeds the 400-line threshold for single PR. Chained PRs recommended.
>
> **Recommendation**: Split into 3 chained PRs:
> 1. **PR 1**: Phase 1 (Ports) — ~800 lines
> 2. **PR 2**: Phase 2+3 (Repos + Services) — ~1500 lines
> 3. **PR 3**: Phase 4+5 (Controllers + Cleanup) — ~700 lines

---

## Phase 1: Ports

### Task 1.1 — Create OptimizerPort behaviour

**Files**: `lib/meal_planner_api/optimization/optimizer_port.ex`

**Dependencies**: None

**Description**:
Define the behaviour for the optimizer integration. The port receives a payload with days, slots, constraints, and candidate recipes, and returns a solved weekly plan.

**Acceptance Criteria**:
- [ ] Behaviour defines `select_weekly_menu/1` callback
- [ ] Behaviour defines `health_check/0` callback
- [ ] Typespecs for payload and result documented
- [ ] Spec documents that optimizer may return `{:error, :optimizer_timeout}` and `{:error, :optimizer_unavailable}`

**Test Strategy**:
- [ ] Behaviour contract test (verify module implements callbacks)

**Estimate**: 30 lines

---

### Task 1.2 — Create OptimizerFallback module

**Files**: `lib/meal_planner_api/optimization/optimizer_fallback.ex`

**Dependencies**: Task 1.1

**Description**:
Implement a greedy heuristic fallback that can generate a valid weekly plan without OR-Tools. Used when the optimizer is unavailable or circuit is open.

**Acceptance Criteria**:
- [ ] Implements `OptimizerPort` behaviour
- [ ] Greedy selection: cheapest recipe per slot that meets kcal target
- [ ] Returns `{:ok, %{"meals" => [...]}}` format
- [ ] Always produces 21 meals (7 days × 3 slots)
- [ ] Handles empty candidates list gracefully

**Test Strategy**:
- [ ] Unit test: returns valid plan for 7 days
- [ ] Unit test: handles missing recipe_id
- [ ] Unit test: handles empty candidates_by_slot
- [ ] Property test: total meals == days × slots

**Estimate**: 80 lines

---

### Task 1.3 — Create OptimizerServer GenServer

**Files**: `lib/meal_planner_api/optimization/optimizer_server.ex`

**Dependencies**: Task 1.1, Task 1.2

**Description**:
Persistent GenServer that owns the Python process via Port. Handles request/response over stdin/stdout, implements circuit breaker, and delegates to fallback when circuit is open.

**Acceptance Criteria**:
- [ ] `start_link/1` spawns Python process via Port
- [ ] Startup handshake: sends `{"type":"handshake","version":"1.0"}`, expects `{"type":"ready"}`
- [ ] `handle_call(:solve, payload)` queues request and sends JSON over Port
- [ ] `handle_info({:port, {:data, raw}})` parses responses and matches to requests
- [ ] Circuit breaker: 3 consecutive failures → circuit opens
- [ ] Circuit reset: after 30 seconds in open state, attempts half-open
- [ ] When circuit open: delegates to `OptimizerFallback.select_weekly_menu/1`
- [ ] Configurable timeout (default 15s)
- [ ] Auto-restart on Python process exit

**Test Strategy**:
- [ ] Mock Python process in tests
- [ ] Test circuit breaker state transitions
- [ ] Test request/response matching by id
- [ ] Integration test with real Python process (optional, tag :integration)

**Estimate**: 250 lines

---

### Task 1.4 — Create OptimizerMock

**Files**: `lib/meal_planner_api/optimization/optimizer_mock.ex`

**Dependencies**: Task 1.1

**Description**:
Test double for `OptimizerPort`. Returns deterministic results for tests.

**Acceptance Criteria**:
- [ ] Implements `OptimizerPort` behaviour
- [ ] `select_weekly_menu/1` returns valid plan with all days and slots
- [ ] `health_check/0` returns `:ok`
- [ ] Configurable to return error on demand (for testing error paths)

**Test Strategy**:
- [ ] Used in service tests (Task 3.x)

**Estimate**: 40 lines

---

### Task 1.5 — Update Python optimizer protocol

**Files**: `optimizador.py`

**Dependencies**: Task 1.3

**Description**:
Update `optimizador.py` to implement the handshake + request/response protocol for GenServer+Port communication.

**Acceptance Criteria**:
- [ ] On startup, wait for handshake `{"type":"handshake",...}`
- [ ] Respond with `{"type":"ready","version":"1.0"}`
- [ ] For each solve request: read line, parse JSON, solve, print response with same `id`
- [ ] Response format: `{"type":"solution","id":"...","result":{...}}` or `{"type":"error","id":"...","error":"..."}`
- [ ] Keep existing OR-Tools logic unchanged
- [ ] Handle malformed JSON gracefully (print error response)

**Test Strategy**:
- [ ] Test with `echo '{"type":"handshake","version":"1.0"}' | python3 optimizador.py`
- [ ] Integration test with OptimizerServer

**Estimate**: 60 lines

---

### Task 1.6 — Create AIPort behaviour

**Files**: `lib/meal_planner_api/ai/ai_port.ex`

**Dependencies**: None

**Description**:
Define the behaviour for AI client integration (Gemini).

**Acceptance Criteria**:
- [ ] Behaviour defines `generate_text/2` callback
- [ ] Behaviour defines `stream_chat/3` callback
- [ ] Typespecs documented

**Test Strategy**:
- [ ] Behaviour contract test

**Estimate**: 20 lines

---

### Task 1.7 — Create GeminiAdapter

**Files**: `lib/meal_planner_api/ai/gemini_adapter.ex`

**Dependencies**: Task 1.6, existing `ai/gemini_client.ex`

**Description**:
Wrap existing `GeminiClient` in an adapter that implements `AIPort`.

**Acceptance Criteria**:
- [ ] Implements `AIPort` behaviour
- [ ] `generate_text/2` wraps `GeminiClient.generate_text/2`
- [ ] `stream_chat/3` wraps `GeminiClient.stream_chat/4`
- [ ] Configuration via application env (keep existing pattern)

**Test Strategy**:
- [ ] Test adapter delegates correctly (mock GeminiClient)

**Estimate**: 40 lines

---

### Task 1.8 — Create AIMock

**Files**: `lib/meal_planner_api/ai/ai_mock.ex`

**Dependencies**: Task 1.6

**Description**:
Test double for `AIPort`.

**Acceptance Criteria**:
- [ ] Implements `AIPort` behaviour
- [ ] Returns configurable responses
- [ ] Tracks calls for assertion in tests

**Test Strategy**:
- [ ] Used in voice parser and service tests

**Estimate**: 30 lines

---

### Task 1.9 — Create VoiceParserPort and implementations

**Files**:
- `lib/meal_planner_api/voice/voice_parser_port.ex`
- `lib/meal_planner_api/voice/rule_based_voice_parser.ex`
- `lib/meal_planner_api/voice/ai_voice_parser.ex`

**Dependencies**: Task 1.6, Task 1.7, Task 1.8

**Description**:
Extract voice parsing from `InventoryHub` into a port with two implementations.

**Acceptance Criteria**:
- [ ] `VoiceParserPort` behaviour with `parse/2` callback
- [ ] `RuleBasedVoiceParser`: pure Elixir, regex-based, no AI
  - Pattern: "mitad del kilo de <name>" → 500ml
  - Pattern: "medio <name>" → half of current quantity
  - Pattern: "<name>" mentioned → quarter of current quantity
- [ ] `AIVoiceParser`: uses `AIPort.generate_text/2` with structured prompt
  - Falls back to `RuleBasedVoiceParser` on AI error
- [ ] Config selects implementation via app env

**Test Strategy**:
- [ ] `RuleBasedVoiceParser` unit tests with various inputs
- [ ] `AIVoiceParser` tests with `AIMock`

**Estimate**: 120 lines

---

## Phase 2: Repos

### Task 2.1 — Create RecipeRepo

**Files**: `lib/meal_planner_api/persistence/recipe_repo.ex`

**Dependencies**: Phase 1 complete

**Description**:
Pure data access for recipes. Replaces logic from `Persistence.Planning.candidate_recipe_ids_for_users/4`.

**Acceptance Criteria**:
- [ ] `list_for_slot/2`: returns recipes for account_id and slot
- [ ] `list_by_ids/1`: returns recipes by ID list
- [ ] `get_by_id/1`: returns single recipe or nil
- [ ] `list_with_ingredients/2`: returns recipes containing given ingredient IDs, ordered by match count
- [ ] No business logic — only Ecto queries
- [ ] Preloads associations as needed
- [ ] Uses existing Recipe schema (no schema changes)

**Test Strategy**:
- [ ] Unit tests with `MealPlannerApi.Repo` sandbox
- [ ] Test query edge cases (empty list, nil account_id)

**Estimate**: 100 lines

---

### Task 2.2 — Create InventoryRepo

**Files**: `lib/meal_planner_api/persistence/inventory_repo.ex`

**Dependencies**: Phase 1 complete

**Description**:
Pure data access for inventory items.

**Acceptance Criteria**:
- [ ] `list_with_ingredient/1`: returns inventory items with ingredient preloaded
- [ ] `get_item/2`: returns single inventory item for account+item_id
- [ ] `upsert_item/3`: insert or update inventory item
- [ ] `apply_delta/3`: update quantity with delta, log mutation event
- [ ] `list_by_category/1`: returns items grouped by ingredient category
- [ ] `list_expiring/2`: returns items expiring within N days

**Test Strategy**:
- [ ] Unit tests with Repo sandbox
- [ ] Test upsert conflict handling

**Estimate**: 120 lines

---

### Task 2.3 — Create AccountRepo

**Files**: `lib/meal_planner_api/persistence/account_repo.ex`

**Dependencies**: Phase 1 complete

**Description**:
Pure data access for accounts and users.

**Acceptance Criteria**:
- [ ] `get_account/1`: returns account by ID
- [ ] `get_user_by_email/1`: returns user by email
- [ ] `get_user/1`: returns user by ID
- [ ] `create_account_and_user/3`: creates account + owner user in transaction
- [ ] `update_user/2`: updates user record
- [ ] `get_budget/1`: returns account default_budget_cents
- [ ] `get_subscription/1`: returns account subscription_plan_id

**Test Strategy**:
- [ ] Unit tests with Repo sandbox

**Estimate**: 80 lines

---

### Task 2.4 — Create PlanningRepo

**Files**: `lib/meal_planner_api/persistence/planning_repo.ex`

**Dependencies**: Phase 1 complete

**Description**:
Pure data access for scheduled meals, proposals, generation runs.

**Acceptance Criteria**:
- [ ] `list_scheduled_meals/3`: returns meals for account_id between dates
- [ ] `upsert_scheduled_meal/1`: insert or update (on_conflict)
- [ ] `list_proposals/1`: returns proposals for account_id
- [ ] `get_proposal/1`: returns proposal by ID
- [ ] `create_proposal/1`: creates planning proposal
- [ ] `update_proposal_status/2`: updates proposal status
- [ ] `create_generation_run/1`: creates generation run
- [ ] `update_generation_run/2`: updates generation run

**Test Strategy**:
- [ ] Unit tests with Repo sandbox

**Estimate**: 100 lines

---

### Task 2.5 — Create ShoppingRepo

**Files**: `lib/meal_planner_api/persistence/shopping_repo.ex`

**Dependencies**: Phase 1 complete

**Description**:
Pure data access for shopping items and checkout sessions.

**Acceptance Criteria**:
- [ ] `list_shopping_items/1`: returns shopping items for account_id
- [ ] `upsert_shopping_item/2`: insert or update
- [ ] `delete_shopping_item/2`: soft delete shopping item
- [ ] `create_checkout_session/1`: creates checkout session
- [ ] `get_checkout_session/1`: returns checkout session by ID
- [ ] `update_checkout_session/2`: updates session status

**Test Strategy**:
- [ ] Unit tests with Repo sandbox

**Estimate**: 80 lines

---

## Phase 3: Services

### Task 3.1 — Create PlanningService

**Files**: `lib/meal_planner_api/planning/planning_service.ex`

**Dependencies**: Tasks 1.1, 1.2, 1.3, 1.4, 2.1, 2.4

**Description**:
Core planning orchestration. Replaces `planning.ex` and `planning_chat.ex`.

**Acceptance Criteria**:
- [ ] `build_weekly_plan/3`: builds weekly plan using optimizer
  - Loads candidates via `RecipeRepo.list_for_slot/2`
  - Calls `OptimizerPort.select_weekly_menu/1`
  - On optimizer error, uses `OptimizerFallback`
  - Returns `WeeklyPlan` struct
- [ ] `confirm_plan/3`: persists confirmed meals
  - Validates no duplicate slots per day
  - Validates recipe ownership
  - Upserts `ScheduledMeal` records
- [ ] `confirm_proposal/3`: confirms a proposal and persists meals
- [ ] `reject_proposal/3`: marks proposal as rejected
- [ ] `serialize_plan/1`: returns map for JSON response
- [ ] All domain logic in service, no HTTP, no DB direct access

**Test Strategy**:
- [ ] Unit tests with `OptimizerMock` and `FakeRecipeRepo`
- [ ] Test fallback when optimizer fails
- [ ] Test validation for duplicate slots
- [ ] Test validation for recipe ownership

**Estimate**: 250 lines

---

### Task 3.2 — Create InventoryService

**Files**: `lib/meal_planner_api/inventory/inventory_service.ex`

**Dependencies**: Tasks 1.9, 2.2

**Description**:
Inventory management orchestration. Replaces `inventory_hub.ex`.

**Acceptance Criteria**:
- [ ] `get_inventory_view/2`: returns inventory grouped by freshness
  - Calls `InventoryRepo.list_with_ingredient/1`
  - Decorates with freshness status (ok/warning/expired)
  - Groups by category and freshness
- [ ] `add_item/3`: adds new inventory item
- [ ] `adjust_quantity/3`: adjusts item quantity with delta
- [ ] `dispose_item/3`: disposes item (sets quantity to 0)
- [ ] `voice_preview/3`: calls `VoiceParserPort.parse/2`, returns ops
- [ ] `voice_apply/3`: applies parsed operations to inventory
- [ ] `rescue_plan/3`: schedules recipe using expiring ingredients

**Test Strategy**:
- [ ] Unit tests with `VoiceParserMock` and `FakeInventoryRepo`
- [ ] Test voice parsing flow
- [ ] Test rescue plan selection

**Estimate**: 200 lines

---

### Task 3.3 — Create RecipeService

**Files**: `lib/meal_planner_api/recipes/recipe_service.ex`

**Dependencies**: Task 2.1

**Description**:
Recipe candidate logic. Moved from `Persistence.Planning.candidate_recipe_ids_for_users/4`.

**Acceptance Criteria**:
- [ ] `list_candidates_for_slot/3`: returns candidates with metadata
  - Loads recipes via `RecipeRepo.list_for_slot/2`
  - Applies user dietary restrictions
  - Orders by inventory hit count
  - Calculates macro values
- [ ] `find_rescue_recipe/2`: finds recipe using given ingredients
  - Uses `RecipeRepo.list_with_ingredients/2`
  - Returns recipe with most ingredient matches
- [ ] `get_recipe/1`: returns recipe by ID with full preload

**Test Strategy**:
- [ ] Unit tests with `FakeRecipeRepo`
- [ ] Test dietary restriction filtering

**Estimate**: 120 lines

---

### Task 3.4 — Create AccountService

**Files**: `lib/meal_planner_api/accounts/account_service.ex`

**Dependencies**: Task 2.3

**Description**:
Account and user management. Simplifies `accounts.ex`.

**Acceptance Criteria**:
- [ ] `register_with_password/1`: registers new user with email/password
- [ ] `authenticate_with_password/1`: authenticates user
- [ ] `register_with_social/1`: registers user via social provider
- [ ] `authenticate_with_social/1`: authenticates via social provider
- [ ] `link_user/2`: links additional user to group account
- [ ] `get_user/1`: returns user by ID
- [ ] `get_account/1`: returns account by ID
- [ ] `serialize_user/1`: returns user map for response
- [ ] `serialize_account/1`: returns account map for response

**Test Strategy**:
- [ ] Unit tests with `FakeAccountRepo`
- [ ] Test individual limit logic

**Estimate**: 150 lines

---

### Task 3.5 — Create SubscriptionService

**Files**: `lib/meal_planner_api/subscriptions/subscription_service.ex`

**Dependencies**: Task 2.3

**Description**:
Subscription management. Simplifies `subscriptions.ex`.

**Acceptance Criteria**:
- [ ] `max_planning_days/1`: returns max days for subscription tier
  - `:free` → 3 days
  - `:premium` → 14 days
  - `:family` → 7 days
- [ ] `tier_default_limit/1`: returns default budget cents for tier
  - `:free` → 45,000
  - `:premium` → 85,000
  - `:family` → 65,000

**Test Strategy**:
- [ ] Unit tests for all tiers

**Estimate**: 40 lines

---

### Task 3.6 — Create BudgetService

**Files**: `lib/meal_planner_api/budgets/budget_service.ex`

**Dependencies**: Task 2.3, Task 3.5

**Description**:
Budget resolution. Simplifies `budgets.ex`.

**Acceptance Criteria**:
- [ ] `resolve_budget/2`: returns budget for user
  - Uses user-provided `weekly_budget_cents` if given
  - Falls back to account default
  - Falls back to tier default
- [ ] `within_limit?/2`: checks if estimated cost is within budget
- [ ] `serialize_budget/1`: returns budget map

**Test Strategy**:
- [ ] Unit tests for all fallback paths

**Estimate**: 60 lines

---

## Phase 4: Controllers

### Task 4.1 — Update FallbackController

**Files**: `lib/meal_planner_api_web/controllers/fallback_controller.ex`

**Dependencies**: Phase 3 complete

**Description**:
Update `FallbackController` to use RFC 7807 Problem Details format.

**Acceptance Criteria**:
- [ ] All error branches return RFC 7807 JSON
- [ ] `type` field uses `https://api.myfood.app/errors/` prefix
- [ ] `status` field matches HTTP status code
- [ ] `title` field is human-readable
- [ ] `instance` field shows request path

**Test Strategy**:
- [ ] Integration tests for all error paths

**Estimate**: 50 lines

---

### Task 4.2 — Update PlanningController

**Files**: `lib/meal_planner_api_web/controllers/planning_controller.ex`

**Dependencies**: Task 4.1, Task 3.1

**Description**:
Replace existing controller with thin layered version.

**Acceptance Criteria**:
- [ ] All actions delegate to `PlanningService`
- [ ] No business logic in controller
- [ ] Extracts user from Guardian claims
- [ ] Formats JSON response
- [ ] Actions: `build_plan`, `confirm_plan`, `confirm_proposal`, `reject_proposal`

**Test Strategy**:
- [ ] Controller tests with authenticated conn

**Estimate**: 60 lines

---

### Task 4.3 — Update InventoryController

**Files**: `lib/meal_planner_api_web/controllers/inventory_controller.ex`

**Dependencies**: Task 4.1, Task 3.2

**Description**:
Replace existing controller with thin layered version.

**Acceptance Criteria**:
- [ ] All actions delegate to `InventoryService`
- [ ] Actions: `index`, `add_item`, `adjust_item`, `dispose_item`, `voice_preview`, `voice_apply`

**Test Strategy**:
- [ ] Controller tests

**Estimate**: 50 lines

---

### Task 4.4 — Update AccountsController

**Files**: `lib/meal_planner_api_web/controllers/accounts_controller.ex`

**Dependencies**: Task 4.1, Task 3.4

**Description**:
Replace existing controller with thin layered version.

**Acceptance Criteria**:
- [ ] All actions delegate to `AccountService`
- [ ] Actions: `me`, `update_profile`

**Test Strategy**:
- [ ] Controller tests

**Estimate**: 30 lines

---

### Task 4.5 — Update AuthController

**Files**: `lib/meal_planner_api_web/controllers/auth_controller.ex`

**Dependencies**: Task 4.1, Task 3.4

**Description**:
Replace existing controller with thin layered version. Keep auth logic (Guardian, social verification) as-is.

**Acceptance Criteria**:
- [ ] `password` action delegates to `AccountService`
- [ ] `social` action delegates to `AccountService`
- [ ] Returns JWT on success
- [ ] Returns proper error codes on failure

**Test Strategy**:
- [ ] Integration tests for auth flow

**Estimate**: 40 lines

---

### Task 4.6 — Update Remaining Controllers

**Files**:
- `lib/meal_planner_api_web/controllers/calendar_controller.ex`
- `lib/meal_planner_api_web/controllers/cooking_controller.ex`
- `lib/meal_planner_api_web/controllers/shopping_controller.ex`

**Dependencies**: Task 4.1

**Description**:
Update remaining controllers to thin pattern.

**Acceptance Criteria**:
- [ ] All actions delegate to appropriate service
- [ ] No business logic

**Test Strategy**:
- [ ] Controller tests

**Estimate**: 40 lines each

---

### Task 4.7 — Update Phoenix Router

**Files**: `lib/meal_planner_api_web/router.ex`

**Dependencies**: Tasks 4.2–4.6

**Description**:
Ensure router routes match new controller actions.

**Acceptance Criteria**:
- [ ] All routes point to new controllers
- [ ] Auth pipeline unchanged
- [ ] CORS unchanged
- [ ] No breaking route changes

**Test Strategy**:
- [ ] Route tests via `Phoenix.ConnTest`
- [ ] Verify all routes dispatch correctly

**Estimate**: 30 lines

---

## Phase 5: Cleanup

### Task 5.1 — Delete Old Modules

**Files to delete**:
```
lib/meal_planner_api/
  ├── accounts.ex
  ├── budgets.ex
  ├── cooking_assistant.ex
  ├── inventory.ex
  ├── inventory_hub.ex
  ├── messages.ex
  ├── planning.ex
  ├── planning_chat.ex
  ├── shopping_checkout.ex
  ├── subscriptions.ex
  ├── ai/
  │   ├── client.ex
  │   ├── gemini_client.ex
  │   └── mock_client.ex
  └── planning/
      ├── optimizer_client.ex
      ├── python_optimizer_client.ex
      ├── mock_optimizer_client.ex
      └── weekly_plan.ex

lib/meal_planner_api_web/
  # (no deletions, all replaced)
```

**Dependencies**: All previous phases

**Acceptance Criteria**:
- [ ] All old modules removed from filesystem
- [ ] No remaining references to deleted modules in codebase
- [ ] Code compiles without warnings

**Test Strategy**:
- [ ] `mix compile --warnings-as-errors`
- [ ] Verify no deprecated module references

**Estimate**: Deletion, no new lines

---

### Task 5.2 — Run Full Test Suite

**Dependencies**: Task 5.1

**Description**:
Run complete test suite and fix any failures.

**Acceptance Criteria**:
- [ ] `mix test` passes with 0 failures
- [ ] No compilation warnings
- [ ] Coverage maintained or improved

**Test Strategy**:
- [ ] Run `mix test --trace`
- [ ] Fix any broken tests

**Estimate**: Varies

---

### Task 5.3 — Verify API Contracts

**Dependencies**: Task 5.2

**Description**:
Verify that API response shapes match original version.

**Acceptance Criteria**:
- [ ] `/api/planning/build` response matches original format
- [ ] `/api/inventory` response matches original format
- [ ] `/api/auth/*` response matches original format
- [ ] All error responses use RFC 7807

**Test Strategy**:
- [ ] Integration tests comparing response shapes

**Estimate**: 50 lines

---

### Task 5.4 — Update Documentation

**Files**: 
- `README.md`
- `ARCHITECTURE.md`
- `AGENTS.md`

**Dependencies**: Task 5.3

**Description**:
Update project documentation to reflect new architecture.

**Acceptance Criteria**:
- [ ] `ARCHITECTURE.md` updated with new layer diagram
- [ ] `README.md` updated with new setup instructions
- [ ] `AGENTS.md` updated with new patterns

**Estimate**: 100 lines

---

## Dependency Graph

```
Phase 1 (Ports)
  ├── 1.1 OptimizerPort
  ├── 1.2 OptimizerFallback ← 1.1
  ├── 1.3 OptimizerServer ← 1.1, 1.2
  ├── 1.4 OptimizerMock ← 1.1
  ├── 1.5 Python protocol ← 1.3
  ├── 1.6 AIPort
  ├── 1.7 GeminiAdapter ← 1.6
  ├── 1.8 AIMock ← 1.6
  └── 1.9 VoiceParser ← 1.6, 1.7, 1.8

Phase 2 (Repos) ← Phase 1
  ├── 2.1 RecipeRepo
  ├── 2.2 InventoryRepo
  ├── 2.3 AccountRepo
  ├── 2.4 PlanningRepo
  └── 2.5 ShoppingRepo

Phase 3 (Services) ← Phase 2, Phase 1
  ├── 3.1 PlanningService ← 1.1, 1.2, 1.3, 1.4, 2.1, 2.4
  ├── 3.2 InventoryService ← 1.9, 2.2
  ├── 3.3 RecipeService ← 2.1
  ├── 3.4 AccountService ← 2.3
  ├── 3.5 SubscriptionService ← 2.3
  └── 3.6 BudgetService ← 2.3, 3.5

Phase 4 (Controllers) ← Phase 3
  ├── 4.1 FallbackController ← Phase 3
  ├── 4.2 PlanningController ← 4.1, 3.1
  ├── 4.3 InventoryController ← 4.1, 3.2
  ├── 4.4 AccountsController ← 4.1, 3.4
  ├── 4.5 AuthController ← 4.1, 3.4
  ├── 4.6 Remaining controllers ← 4.1
  └── 4.7 Router ← 4.2-4.6

Phase 5 (Cleanup) ← Phase 4
  ├── 5.1 Delete old modules
  ├── 5.2 Run tests
  ├── 5.3 Verify contracts
  └── 5.4 Update docs
```

---

## Review Workload Forecast

| PR | Changes | Lines | Tasks |
|---|---|---|---|
| **PR 1** | Phase 1 (Ports) | ~800 | 9 tasks |
| **PR 2** | Phase 2+3 (Repos + Services) | ~1500 | 11 tasks |
| **PR 3** | Phase 4+5 (Controllers + Cleanup) | ~700 | 11 tasks |

**Recommendation**: Use chained PRs with automated forecasting. Each PR must pass tests before next PR is merged.

---

*Tasks created: 2026-06-01*
*Status: ready for apply*