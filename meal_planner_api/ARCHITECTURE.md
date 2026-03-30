# Meal Planner API Skeleton (No DB)

This backend is intentionally database-free for now.
All business logic uses pure Elixir structs and maps, with mock data and deterministic flows.

## Clean Architecture Boundaries

### Web Layer (Delivery)
- `lib/meal_planner_api_web/router.ex`
  - Public route for token minting.
  - Protected routes for account/profile and planning APIs.
- `lib/meal_planner_api_web/controllers/auth_controller.ex`
  - Issues JWT with account claims.
- `lib/meal_planner_api_web/controllers/accounts_controller.ex`
  - Returns authenticated user and claims.
- `lib/meal_planner_api_web/controllers/planning_controller.ex`
  - Returns mock weekly meal plan.
- `lib/meal_planner_api_web/user_socket.ex`
  - Validates JWT for WebSocket connection.
- `lib/meal_planner_api_web/channels/ai_channel.ex`
  - Handles `new_message` and triggers streaming responses.

### Application Layer (Use Cases)
- `lib/meal_planner_api/accounts.ex`
  - Individual vs group account rules.
  - Linked user restriction policy.
  - Claim composition for JWT.
- `lib/meal_planner_api/planning.ex`
  - Weekly meal planning use-case with account-aware behavior.
- `lib/meal_planner_api/ai.ex`
  - AI context boundary delegating to configured provider.

### Domain Layer (Core Models)
- `lib/meal_planner_api/accounts/user.ex`
- `lib/meal_planner_api/accounts/account.ex`
- `lib/meal_planner_api/planning/weekly_plan.ex`

### Infrastructure Layer (Adapters)
- `lib/meal_planner_api/auth/guardian.ex`
  - JWT encode/decode integration.
- `lib/meal_planner_api/ai/client.ex`
  - AI behavior contract.
- `lib/meal_planner_api/ai/mock_client.ex`
  - Mock streaming adapter that emits `ai_response_chunk`.

## Auth Flow (HTTP + WS)

1. Client requests token:
  - `POST /api/auth/password` (email/password)
  - `POST /api/auth/social` (Google/Apple/Facebook)
2. Client uses token for protected REST APIs:
   - `Authorization: Bearer <token>`
3. Client uses same token for socket connect params:
   - `ws://localhost:4000/socket/websocket?token=<token>&vsn=2.0.0`
4. Socket join topic:
   - `ai_chat:<room_id>`

## WebSocket Streaming Contract

### Inbound event
- event: `new_message`
- payload: `%{"message" => "Build me a weekly high-protein plan"}`

### Outbound event
- event: `ai_response_chunk`
- payload chunk: `%{chunk: "...", done: false}`
- completion chunk: `%{chunk: "", done: true}`

## Group vs Individual Rules

- `:individual`
  - max linked users: 1
  - additional links beyond one return `{:error, :individual_limit_reached}`
- `:group`
  - linked users: unlimited in current mock

## Config Knobs

- `config/config.exs`
  - `:ai_client` points to `MealPlannerApi.AI.MockClient`
  - Guardian issuer and secret settings.

## No Persistence Guarantee

This skeleton intentionally includes:
- no Ecto
- no Repo
- no migrations
- no database schemas

All state is generated and returned in-memory to support early API and socket integration from React Native.
