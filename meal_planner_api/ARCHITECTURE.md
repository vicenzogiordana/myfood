# Meal Planner API Architecture

The application is built in Elixir/Phoenix, following Domain-Driven Design and Clean Architecture principles. It persists state using PostgreSQL and Ecto.

## Clean Architecture Boundaries

### Web Layer (Delivery)
- `lib/meal_planner_api_web/router.ex`: Defines public and protected routes.
- `lib/meal_planner_api_web/controllers/`: Receives HTTP requests, calls the Application Layer, and formats JSON responses.
- `lib/meal_planner_api_web/channels/`: Handles WebSocket connections and streaming responses (e.g., AI chat).

### Application Layer (Use Cases / Contexts)
Contains business logic and orchestration. This layer coordinates between the domain, persistence, and external services.
- `MealPlannerApi.Accounts`: Handles user registration, dietary profiles, and subscriptions.
- `MealPlannerApi.Planning`: Orchestrates weekly meal planning, optimization logic, and proposal confirmations.
- `MealPlannerApi.PlanningChat`: Handles the AI conversational flow for meal planning and invokes the AI models.
- `MealPlannerApi.InventoryHub`: Coordinates ingredient tracking and shopping logic.

### Persistence Layer (Adapters)
Responsible for interacting with the database. The application layer delegates data retrieval and storage to this layer, keeping Ecto schemas isolated from the core business workflows.
- `MealPlannerApi.Persistence.Accounts`: Queries and schemas for users, accounts, and RevenueCat data.
- `MealPlannerApi.Persistence.Planning`: Queries and schemas for scheduled meals, proposals, and generation runs.
- `MealPlannerApi.Persistence.Catalog`: Queries and schemas for recipes and ingredients.

### Infrastructure Layer (External Services)
- `MealPlannerApi.AI.GeminiClient`: Implements true HTTP Server-Sent Events (SSE) streaming with Google's Gemini API.
- `MealPlannerApi.Planning.PythonOptimizerClient`: Integrates with a local Python script running Google OR-Tools to solve the nutritional and budget constraints for meal proposals.

## Auth Flow (HTTP + WS)
1. Token Minting: `POST /api/auth/password` or `POST /api/auth/social` returns a JWT via Guardian.
2. HTTP Access: The JWT is passed as a Bearer token in the `Authorization` header.
3. WebSocket Access: The JWT is passed as a `token` query parameter to connect to Phoenix Channels.

## Group vs Individual Rules
- `:individual`: Maximum of 1 linked user.
- `:group`: Allows multiple linked users under the same account.

## Integrations
- **RevenueCat**: Webhook processing and active entitlement synchronization update user subscription tiers.
- **OR-Tools (Python)**: The Elixir backend executes an external `optimizador.py` script via `System.cmd` to run the constraint solver over recipes.
- **Gemini**: Used for the conversational interface, providing a fully streamed AI experience.