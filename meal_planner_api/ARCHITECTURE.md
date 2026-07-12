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

Phase A ("Tenancy Refactor") introduced a dual-token model: a legacy
single-Account token (`access`, aka `access_v1`) and a membership-scoped
token (`access_v2`). Both remain valid indefinitely during the dual-write
window (see "Env-var cutover" below) — the pipeline verifies either type
on every request.

### Token types and claim shapes

**`access` (legacy, `typ: "access"`)** — minted by `Accounts.claims_for/2`.
One User, implicitly one Account (`user.account_id`).

```json
{
  "sub": "<user_id>",
  "typ": "access",
  "account_id": "<account_id>",
  "email": "user@example.com",
  "name": "User Name",
  "iat": 1700000000,
  "exp": 1702592000
}
```

**`access_v2` (`typ: "access_v2"`)** — minted by
`AccountsMembership.claims_for/2`. Carries the specific
`AccountMembership` the token is scoped to, so a single User with
memberships in several Accounts (multi-familia) can hold one token per
Account and switch between them without re-authenticating.

```json
{
  "sub": "<user_id>",
  "typ": "access_v2",
  "membership_id": "<account_membership_id>",
  "account_id": "<account_id>",
  "role": "owner",
  "plan": "family_4",
  "status": "active",
  "email": "user@example.com",
  "name": "User Name",
  "iat": 1700000000,
  "exp": 1702592000
}
```

The `account_id` claim in `access_v2` is redundant/informational only —
`membership_id` is the canonical scope pointer. `LoadCurrentMembership`
always re-resolves `current_membership` from the database via
`membership_id`, never trusts the `account_id` claim directly (see
"Pipeline" below).

### Pipeline (`MealPlannerApiWeb.AuthPipeline`)

Every `:auth`-piped HTTP request (and the WebSocket `UserSocket.connect/3`
equivalent) runs through:

```
Bearer token
   │
   ▼
Guardian.Plug.VerifyHeader        — validates signature + standard claims
   │
   ▼
Plugs.VerifyTokenType              — typ ∈ {"access", "access_v2"},
   │                                 else 401 unsupported_token_type
   ▼
Guardian.Plug.EnsureAuthenticated  — 401 if unauthenticated
   │
   ▼
Guardian.Plug.LoadResource         — conn.assigns.current_user (%User{})
   │                                 (allow_blank: false)
   ▼
Plugs.LoadCurrentMembership        — conn.assigns.current_membership
   │                                 (%AccountMembership{}, ALWAYS a real,
   │                                 :active DB row — see below)
   ▼
[controller / channel join]
   │
   ▼
Plugs.EnforceAccountScope          — only for :account_id-bearing routes
                                      (scope "/api/accounts/:account_id");
                                      403 account_mismatch if
                                      conn.path_params["account_id"] !=
                                      current_membership.account_id
```

`LoadCurrentMembership` resolves `current_membership` differently per
`typ`, but in both cases the result is a REAL `AccountMembership` row —
there is no "synthesized" in-memory struct:

- `access_v2` → loads the row by `claims["membership_id"]`.
- `access` (legacy) → loads the row for
  `(current_user.id, current_user.account_id)` with `status: :active`.
  If no such row exists (e.g. the member was removed, or never had one),
  the request is refused with `401 membership_id_required` — a stale
  legacy token from a removed member does NOT keep working just because
  its 4-week TTL hasn't expired yet.

Controllers and services MUST read `conn.assigns.current_membership.
account_id` for tenancy scoping, never `conn.assigns.current_user.
account_id` — `current_user.account_id` is a dual-write compatibility
shim only (Guardian's `resource_from_claims/1` re-attaches it from the
JWT's claim for `LoadCurrentMembership`'s own internal use) and is
scheduled for removal once `access_v1` is retired (see "Env-var cutover").

### `EnforceAccountScope`

Applies only to routes with an `:account_id` path segment (invites,
membership roster/removal, leave). Compares
`conn.path_params["account_id"]` against
`conn.assigns.current_membership.account_id`; halts with
`403 account_mismatch` on any mismatch. Routes with no `:account_id` in
the URL (`/api/calendar`, `/api/planning/*`, `/api/cooking/*`,
`/api/inventory`, `/api/shopping-*`, ...) are NOT behind this plug —
their isolation is enforced by always reading
`current_membership.account_id` inside the controller/service instead
(see `test/meal_planner_api_web/cross_account_isolation_test.exs`).

### Env-var cutover (`MEAL_PLANNER_TENANCY_V2`)

`Application.get_env(:meal_planner_api, :tenancy_v2_only, false)`
controls which token TYPE is *minted* (verification always accepts
both):

- `false` (default) — `AuthController`, `AccountLifecycleController`, and
  `Accounts.authenticate_with_password/1` mint `access` (`access_v1`).
- `true` — the same code paths mint `access_v2` instead, using the
  User's membership via `AccountsMembership.claims_for/2`.

The flip is a pure config/env-var change — no DB migration, no app
release. Existing `access` tokens keep verifying after the flip (until
their normal TTL expires); no forced re-login. Follow-up change
`tenancy-v2-hardening` (post-Phase-A) removes `access_v1` issuance once
the React Native client fully consumes `current_membership`.

### Sequence: invite → accept → switch-account

```
Owner (Account A)                 API                          Invitee
      │                            │                               │
      │  POST /api/accounts/:A/invites {email}                     │
      │ ─────────────────────────►│                                │
      │                            │ AccountsMembership.invite/3    │
      │                            │  - :owner check                │
      │                            │  - seat cap check               │
      │                            │  - mint token, hash, store      │
      │  201 {invite: {token, expires_at, membership_id}}            │
      │◄───────────────────────────│                                │
      │                            │                                │
      │                            │   POST /api/invites/:token/accept
      │                            │◄───────────────────────────────│
      │                            │ AccountsMembership.accept_invite/2
      │                            │  - verify + consume token (single-use)
      │                            │  - flip :invited → :active
      │                            │  - claims_for/2 → access_v2 (Account A)
      │                            │  200 {access_token, membership, ...}
      │                            │────────────────────────────────►│
      │                            │                                 │
      │                            │  (invitee now also has/gains a  │
      │                            │   second membership, Account B) │
      │                            │                                 │
      │                            │   POST /api/auth/switch-account │
      │                            │   {membership_id: <Account B>}  │
      │                            │◄─────────────────────────────── │
      │                            │ AccountsMembership.switch_account/2
      │                            │  - ownership check (membership.user_id)
      │                            │  - :active status check
      │                            │  - claims_for/2 → access_v2 (Account B)
      │                            │  200 {access_token, account: B, ...}
      │                            │────────────────────────────────►│
```

## Multi-Account Plans

Phase A replaced the legacy `:individual` / `:group` `account_type`
enum with `Account.plan` (`:individual | :family_4 | :family_6 |
:trial`), resolved through the `subscription_plans` table for seat caps
and planning-day limits. A single User can hold one `AccountMembership`
per Account (multi-familia) and switch the active Account via
`POST /api/auth/switch-account` without re-authenticating — see "Auth
Flow" above.

## Integrations
- **RevenueCat**: Webhook processing and active entitlement synchronization update user subscription tiers.
- **OR-Tools (Python)**: The Elixir backend executes an external `optimizador.py` script via `System.cmd` to run the constraint solver over recipes.
- **Gemini**: Used for the conversational interface, providing a fully streamed AI experience.