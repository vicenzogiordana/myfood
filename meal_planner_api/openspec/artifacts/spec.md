# SDD Spec: MealPlannerApi — Full Architecture Redo

## Change Summary

Delta specs for implementing clean 3-layer architecture with ports and adapters for external integrations.

---

## Layer Definitions

### Layer 1: Web (Controllers + Channels)

**Responsibility**: HTTP/WebSocket boundary only.

**Rules**:
- Receive request, extract params, call appropriate Service
- Format response (JSON, SSE, WS events)
- No business logic
- No DB queries
- No external service calls
- Auth pipeline handled by `MealPlannerApiWeb.AuthPipeline` (existing, not changed)

**Files created**:
```
lib/meal_planner_api_web/controllers/
  ├── planning_controller.ex      # replaces current (new layered version)
  ├── inventory_controller.ex     # replaces current
  ├── accounts_controller.ex      # replaces current
  ├── auth_controller.ex          # replaces current
  ├── calendar_controller.ex      # replaces current
  ├── cooking_controller.ex       # replaces current
  ├── shopping_controller.ex      # replaces current
  └── revenuecat_controller.ex    # keeps current (out of scope)

lib/meal_planner_api_web/channels/
  ├── planning_channel.ex         # replaces current
  ├── ai_channel.ex               # replaces current
  ├── calendar_channel.ex         # replaces current
  └── cooking_channel.ex          # replaces current
```

### Layer 2: Application (Services)

**Responsibility**: Orchestration and use cases.

**Rules**:
- No HTTP parsing
- No direct DB queries (use Data layer)
- No direct external calls (use Ports)
- Receives injected dependencies (ports)
- Contains business logic and orchestration

**Modules created**:

```
lib/meal_planner_api/
  # Core domain
  ├── planning/
  │   └── planning_service.ex      # Weekly planning orchestration
  ├── inventory/
  │   └── inventory_service.ex    # Inventory management
  ├── recipes/
  │   └── recipe_service.ex       # Recipe and candidate logic (moved from persistence)
  ├── accounts/
  │   └── account_service.ex      # User/account management
  └── subscriptions/
      └── subscription_service.ex # Subscription management

  # Ports (behaviours)
  ├── optimization/
  │   ├── optimizer_port.ex       # Behaviour definition
  │   ├── optimizer_server.ex     # GenServer + Port implementation
  │   ├── optimizer_fallback.ex   # Fallback when circuit open
  │   └── optimizer_mock.ex        # For testing
  ├── ai/
  │   ├── ai_port.ex              # Behaviour definition
  │   ├── gemini_adapter.ex       # Gemini implementation
  │   └── ai_mock.ex              # For testing
  └── voice/
      ├── voice_parser_port.ex    # Behaviour definition
      ├── ai_voice_parser.ex      # AI-backed implementation
      └── rule_based_voice_parser.ex  # Pure Elixir implementation

  # Data access (repositories)
  ├── persistence/
  │   ├── recipe_repo.ex          # Pure data access for recipes
  │   ├── ingredient_repo.ex       # Pure data access for ingredients
  │   ├── inventory_repo.ex        # Pure data access for inventory
  │   ├── account_repo.ex         # Pure data access for accounts/users
  │   ├── planning_repo.ex        # Pure data access for scheduled meals
  │   └── shopping_repo.ex        # Pure data access for shopping
```

### Layer 3: Data (Persistence + Schemas)

**Responsibility**: Pure data access, Ecto schemas.

**Rules**:
- Only DB queries and Ecto schemas
- No business logic
- No orchestration
- Named as `*_repo.ex` for data access, `*_schema.ex` for Ecto schemas

**Files created/reorganized**:

```
lib/meal_planner_api/persistence/
  ├── recipe_schema.ex            # Ecto schema (moved from catalog/recipe.ex)
  ├── ingredient_schema.ex        # Ecto schema
  ├── inventory_item_schema.ex    # Ecto schema
  ├── account_schema.ex           # Ecto schema
  ├── user_schema.ex              # Ecto schema
  ├── scheduled_meal_schema.ex    # Ecto schema
  ├── shopping_item_schema.ex     # Ecto schema
  └── supermarket_schema.ex       # Ecto schema
```

---

## Port Specifications

### 1. OptimizerPort

**Behaviour**:
```elixir
defmodule MealPlannerApi.Optimization.OptimizerPort do
  @type optimizer_payload :: %{
    days: [String.t()],
    slots: [String.t()],
    constraints: %{
      kcal_target: integer(),
      weekly_budget_cents: integer(),
      account_type: String.t(),
      subscription_tier: String.t(),
      inventory_items: [String.t()],
      macro_bounds: %{
        protein_g: %{min: float(), max: float()},
        carbs_g: %{min: float(), max: float()},
        fat_g: %{min: float(), max: float()}
      }
    },
    candidates_by_slot: %{
      String.t() => [
        %{
          recipe_id: String.t(),
          slot: String.t(),
          label: String.t(),
          kcal: float(),
          estimated_cost_cents: integer(),
          inventory_hit_count: integer(),
          protein_g_per_serving: float(),
          carbs_g_per_serving: float(),
          fat_g_per_serving: float()
        }
      ]
    }
  }

  @callback select_weekly_menu(optimizer_payload()) :: {:ok, %{meals: [%{day: String.t(), slot: String.t(), recipe_id: String.t()}]}} | {:error, term()}
  @callback health_check() :: :ok | {:error, term()}
end
```

**Implementation: OptimizerServer (GenServer + Port)**:

```
State:
  - port: Port reference
  - python_pid: PID of Python process
  - circuit_state: :closed | :half_open | :open
  - consecutive_failures: non_neg_integer()
  - request_queue: queue of pending requests

Startup:
  1. Spawn Python process via Port
  2. Send handshake JSON {"type": "handshake", "version": "1.0"}
  3. Wait for {"type": "ready"} response
  4. Mark as ready

Communication Protocol:
  Request:
    {"type": "solve", "id": "<uuid>", "payload": {...}}
  Response:
    {"type": "solution", "id": "<uuid>", "result": {...}}
    {"type": "error", "id": "<uuid>", "error": "..."}

Circuit Breaker:
  - Threshold: 3 consecutive failures
  - Reset after: 30 seconds (configurable)
  - When open: delegate to OptimizerFallback

Fallback: OptimizerFallback
  - Simple greedy algorithm
  - Selects cheapest recipe per slot that meets macro bounds
  - No constraint solver, just heuristics
  - Produces valid (suboptimal) weekly plan
```

**Config**:
```elixir
config :meal_planner_api, MealPlannerApi.Optimization.OptimizerServer,
  python_executable: System.get_env("MEAL_PLANNER_OPTIMIZER_PYTHON", "python3"),
  script_path: Path.expand("../optimizer.py", File.cwd!()),
  timeout_ms: 15_000,
  circuit_failure_threshold: 3,
  circuit_reset_timeout_ms: 30_000,
  max_retries: 2
```

### 2. AIPort

**Behaviour**:
```elixir
defmodule MealPlannerApi.AI.AIPort do
  @callback generate_text(prompt :: String.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback stream_chat(prompt :: String.t(), topic :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
end
```

**Implementation: GeminiAdapter**

- Wraps `MealPlannerApi.AI.GeminiClient` (existing, keep as-is)
- Implements `AIPort` behaviour
- Configuration via `runtime.exs` env vars

### 3. VoiceParserPort

**Behaviour**:
```elixir
defmodule MealPlannerApi.Voice.VoiceParserPort do
  @type inventory_item :: %{
    id: String.t(),
    name: String.t(),
    quantity_milli: integer()
  }

  @type parsed_operation :: %{
    inventory_item_id: String.t(),
    quantity_milli: integer()
  }

  @callback parse(text :: String.t(), items :: [inventory_item()]) :: {:ok, [parsed_operation()]} | {:error, term()}
end
```

**Implementations**:

1. `AIVoiceParser` — uses `AIPort.generate_text/2` with structured prompt
2. `RuleBasedVoiceParser` — pure Elixir, regex-based, no AI

**Selection**: Via application config. Default: `AIVoiceParser` with `RuleBasedVoiceParser` as fallback if AI fails.

---

## Service Specifications

### PlanningService

**Public API**:
```elixir
defmodule MealPlannerApi.Planning.PlanningService do
  @spec build_weekly_plan(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_weekly_plan(user, params)

  @spec confirm_plan(map(), map()) :: {:ok, map()} | {:error, term()}
  def confirm_plan(user, payload)

  @spec confirm_proposal(binary(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  def confirm_proposal(account_id, user_id, proposal_id)

  @spec reject_proposal(binary(), binary(), binary()) :: {:ok, map()} | {:error, term()}
  def reject_proposal(account_id, user_id, proposal_id)
end
```

**Dependencies** (injected):
- `MealPlannerApi.Optimization.OptimizerPort` (behaviour)
- `MealPlannerApi.Persistence.PlanningRepo` (data access)
- `MealPlannerApi.Recipes.RecipeService` (candidate logic)

**Logic**:
- Calls `OptimizerPort.select_weekly_menu/1`
- On failure, calls injected fallback
- Constructs `WeeklyPlan` struct
- Returns serialized response

### InventoryService

**Public API**:
```elixir
defmodule MealPlannerApi.Inventory.InventoryService do
  @spec get_inventory_view(map()) :: {:ok, map()} | {:error, term()}
  def get_inventory_view(user)

  @spec add_item(map(), map()) :: {:ok, map()} | {:error, term()}
  def add_item(user, payload)

  @spec adjust_quantity(map(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def adjust_quantity(user, item_id, payload)

  @spec dispose_item(map(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def dispose_item(user, item_id, payload)

  @spec voice_preview(map(), binary()) :: {:ok, map()} | {:error, term()}
  def voice_preview(user, text)

  @spec voice_apply(map(), [map()]) :: {:ok, map()} | {:error, term()}
  def voice_apply(user, operations)

  @spec rescue_plan(map(), map()) :: {:ok, map()} | {:error, term()}
  def rescue_plan(user, payload)
end
```

**Dependencies** (injected):
- `MealPlannerApi.Voice.VoiceParserPort` (behaviour)
- `MealPlannerApi.Persistence.InventoryRepo` (data access)

**Logic**:
- `voice_preview`: calls `VoiceParserPort.parse/2`, returns ops for confirmation
- `voice_apply`: executes parsed operations
- `rescue_plan`: picks recipe using `RecipeService.find_rescue_recipe/2`

### RecipeService

**Public API**:
```elixir
defmodule MealPlannerApi.Recipes.RecipeService do
  @spec list_candidates_for_slot(binary(), [binary()], atom()) :: [map()]
  def list_candidates_for_slot(account_id, user_ids, slot)

  @spec find_rescue_recipe(binary(), [binary()]) :: {:ok, map()} | {:error, :not_found}
  def find_rescue_recipe(account_id, ingredient_ids)
end
```

**Logic** (moved from `Persistence.Planning.candidate_recipe_ids_for_users/4`):
- Queries recipes with ingredients from inventory
- Applies dietary restrictions (excluded ingredients per user profile)
- Orders by inventory hit count (use what you have first)
- Returns candidates with metadata

---

## Controller Specifications

### Thin Controller Pattern

All controllers follow this pattern:

```elixir
defmodule MealPlannerApiWeb.PlanningController do
  use MealPlannerApiWeb, :controller

  action_fallback MealPlannerApiWeb.FallbackController

  def build_plan(conn, %{"user" => user, "params" => params}) do
    case PlanningService.build_weekly_plan(user, params) do
      {:ok, plan} -> json(conn, plan)
      {:error, reason} -> {:error, reason}
    end
  end
end
```

**Error handling**: `FallbackController` handles all `{:error, reason}` tuples.

---

## Error Format (RFC 7807)

All error responses use Problem Details format:

```json
{
  "type": "https://api.myfood.app/errors/validation-failed",
  "title": "Validation Failed",
  "status": 422,
  "detail": "The request body contains invalid fields.",
  "instance": "/api/planning/build",
  "errors": [
    {"field": "kcal_target", "message": "must be a positive integer"}
  ]
}
```

**Existing error mapping**:
- `:invalid_payload` → 400
- `:unauthorized` → 401
- `:forbidden` → 403
- `:not_found` → 404
- `:invalid_meals` → 422
- `:optimizer_timeout` → 503
- `:optimizer_unavailable` → 503

---

## Data Access (Repo Pattern)

All repo modules follow:

```elixir
defmodule MealPlannerApi.Persistence.RecipeRepo do
  import Ecto.Query

  @spec list_for_slot(binary(), atom()) :: [Recipe.t()]
  def list_for_slot(account_id, slot) do
    # pure query, no business logic
  end

  @spec get_by_id(binary()) :: Recipe.t() | nil
  def get_by_id(id) do
    Repo.get(Recipe, id)
  end

  @spec list_by_ids([binary()]) :: [Recipe.t()]
  def list_by_ids(ids) when is_list(ids) do
    Repo.all(from r in Recipe, where: r.id in ^ids)
  end
end
```

**Naming convention**:
- Data access: `*_repo.ex`
- Ecto schema: `*_schema.ex`
- No `Persistence.` prefix for new modules — modules live in their own namespace

---

## File Elimination Plan

**Files to delete** (original tangled architecture):
```
lib/meal_planner_api/
  ├── accounts.ex                           # → AccountService
  ├── budgets.ex                           # → inline in services
  ├── cooking_assistant.ex                 # → (review)
  ├── inventory_hub.ex                     # → InventoryService
  ├── planning.ex                          # → PlanningService
  ├── planning_chat.ex                     # → PlanningService
  ├── subscriptions.ex                    # → SubscriptionService
  ├── messages.ex                         # → (review if needed)
  ├── shopping_checkout.ex                 # → (review if needed)
  ├── inventory.ex                        # → InventoryService
  ├── planning/
  │   ├── optimizer_client.ex             # → OptimizerPort
  │   ├── python_optimizer_client.ex       # → OptimizerServer
  │   ├── mock_optimizer_client.ex        # → OptimizerMock
  │   └── weekly_plan.ex                  # → planning_service.ex
  └── ai/
      ├── client.ex                       # → AIPort
      ├── gemini_client.ex                # → GeminiAdapter
      └── mock_client.ex                  # → AIMock

lib/meal_planner_api_web/
  # Controllers stay (replaced), but paths may change
  # (same paths, new layered implementation)
```

**Files to keep**:
```
lib/meal_planner_api/
  ├── auth/guardian.ex                    # Keep, works fine
  ├── auth/social_verifier.ex             # Keep, works fine
  ├── persistence/accounts/              # → AccountRepo + schemas
  ├── persistence/catalog/               # → RecipeRepo + schemas
  ├── persistence/inventory/             # → InventoryRepo + schemas
  ├── persistence/planning/              # → PlanningRepo + schemas
  ├── persistence/shopping/              # → ShoppingRepo + schemas
  └── persistence/calendar.ex            # → CalendarRepo

lib/meal_planner_api_web/
  ├── router.ex                           # Keep, adapt routes
  ├── endpoint.ex                        # Keep
  ├── telemetry.ex                       # Keep
  ├── user_socket.ex                     # Keep
  └── auth_pipeline.ex                   # Keep
```

---

## Migration Order

1. **Create ports** (OptimizerPort, AIPort, VoiceParserPort) + implementations
2. **Create repos** (pure data access, no logic)
3. **Create services** (use ports, use repos)
4. **Update controllers** (delegate to services, format responses)
5. **Update channels** (same pattern)
6. **Delete old modules** (after verification)
7. **Run tests**, fix failures
8. **Verify API contracts** (response shapes match old version)

---

## Acceptance Scenarios

### AS1: Weekly Plan Generation

**Given** a user with dietary profile and inventory
**When** POST `/api/planning/build` is called with kcal_target and days
**Then** the response contains a weekly plan with meals per day and slot
**And** the optimizer is called via OptimizerServer (not System.cmd)
**And** if optimizer fails, fallback returns a valid (suboptimal) plan

### AS2: Optimizer Circuit Breaker

**Given** optimizer has 3 consecutive failures
**When** next `select_weekly_menu/1` is called
**Then** circuit opens and fallback is used immediately
**And** after 30 seconds, circuit attempts half-open state

### AS3: Voice Inventory Operations

**Given** user says "usé mitad de las verduras"
**When** POST `/api/inventory/voice-preview` is called
**Then** VoiceParserPort.parse/2 returns operations
**And** on confirmation, operations are applied to inventory

### AS4: Controller Has No Business Logic

**Given** any controller action
**When** it handles a request
**Then** it only extracts params, calls a service, and formats response
**And** no business logic exists in controller files

### AS5: Repo Has No Business Logic

**Given** any repo module
**When** it executes a query
**Then** it only performs data access
**And** no business rules exist in repo files

---

*Spec created: 2026-06-01*
*Status: pending design*