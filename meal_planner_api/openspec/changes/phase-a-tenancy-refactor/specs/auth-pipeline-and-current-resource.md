# Auth Pipeline and Current Resource

## Purpose

Defines what `MealPlannerApiWeb.AuthPipeline` populates on the connection
and the WebSocket, and how controllers / channels resolve the active
tenancy. This spec is **MODIFIED** — pre-Phase A only `current_user` is
loaded; post-Phase A both `current_user` and `current_membership` are
available, and controllers / channels MUST read `membership.account_id`.

**Grill decisions referenced**: `context.md` §2 (Clean Architecture —
controllers stay thin), §4 (membership is the source of truth for
tenancy), proposal §"Approach — Feature flag" (dual-write governs the
transition).

## Current Behavior (pre-Phase A)

`MealPlannerApiWeb.AuthPipeline`:

- `Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"}`
- `Guardian.Plug.EnsureAuthenticated`
- `Guardian.Plug.LoadResource, allow_blank: false` — loads the `User`
  struct (re-attach `:account_type`, `:subscription_tier`, `:account_id`
  from claims).

`MealPlannerApiWeb.UserSocket.connect/3` calls
`Guardian.resource_from_token/1` and assigns `current_user`. Controllers
(e.g. `CalendarController`, `PlanningController`, `AccountsController`)
read `current_user.account_id`. Channels do
`if user.account_id == account_id` (e.g. `PlanningChannel.join/3`,
`CalendarChannel.join/3`). No `current_membership` exists.

## Dual-Write Interaction

During the cutover window both `typ: "access"` (legacy) and
`typ: "access_v2"` (new) tokens are accepted. The pipeline MUST populate
`current_membership` for both:

- `access_v2` → `current_membership` is the row identified by the JWT
  `membership_id` claim; `current_user.account_id` MAY be `nil` (decision
  5.1 dual-write window).
- `access` (legacy fallback) → the pipeline synthesizes a "virtual"
  `current_membership` from `User.account_id` and `User.role` for
  controller / channel consumption only; no row is inserted. The
  controller code path is identical to the `access_v2` path.

This dual-write fallback is what makes the cutover safe: legacy clients
keep working while new code reads `current_membership.account_id`.

## New Behavior (Phase A)

### Requirement: Pipeline populates current_user and current_membership

For every authenticated HTTP request and WebSocket connection the pipeline
MUST assign:

- `current_user` — the `User` struct (unchanged; `account_id` MAY be `nil`
  during the dual-write window for `access_v2`).
- `current_membership` — the `AccountMembership` struct (or the virtual
  fallback) carrying `account_id`, `role`, `plan`, `status`.

#### Scenario: access_v2 HTTP request

- GIVEN a Bearer JWT with `typ: "access_v2"` and `membership_id: M1`
- WHEN the request hits an `:auth`-piped route
- THEN `conn.assigns.current_user.id == User.id` AND
  `conn.assigns.current_membership.account_id == M1.account_id` AND
  `current_membership.role == M1.role` AND
  `current_membership.status == M1.status`

#### Scenario: access_v1 HTTP request (dual-write fallback)

- GIVEN a Bearer JWT with `typ: "access"` and `account_id: A1`
- WHEN the request hits an `:auth`-piped route
- THEN `conn.assigns.current_membership.account_id == A1` (synthesized
  from `user.account_id`), `role == user.role`, `plan` is read from
  `Account.plan` via the membership's account

#### Scenario: WebSocket connect with access_v2 token

- GIVEN a client passes `params: { token: <access_v2> }`
- WHEN `UserSocket.connect/3` runs
- THEN `socket.assigns.current_user` is the User AND
  `socket.assigns.current_membership.account_id` matches the JWT's
  `membership_id` claim

### Requirement: URL account_id must match JWT account_id

For requests whose URL contains an `:account_id` path segment, the pipeline
MUST reject with `403 account_mismatch` if the URL `:account_id` does not
equal `current_membership.account_id`. The check runs **before** any
controller action.

#### Scenario: URL/JWT mismatch on /api/accounts/:id/memberships

- GIVEN a JWT scoped to `Account_A` (`current_membership.account_id = A`)
- WHEN the client calls `GET /api/accounts/<B>/memberships` with `<B> ≠ A`
- THEN the pipeline returns `403 account_mismatch` and the controller does
  not run

#### Scenario: Cross-membership URL access denied even with valid User

- GIVEN `User_U` is `:active` in BOTH `Account_A` and `Account_B`, JWT
  scoped to `Account_A`
- WHEN `User_U` calls `GET /api/accounts/<B>/memberships`
- THEN the pipeline rejects with `403 account_mismatch` — the active
  membership is `Account_A`; being a member of `Account_B` is not enough

### Requirement: Controllers read membership.account_id

Every controller that today reads `current_user.account_id` SHALL be
rewritten to read `current_membership.account_id`. The change MUST be
mechanical (per proposal §Stream B):

1. `user.account_id` (read in controllers) →
   `current_membership.account_id`
2. `Repo.get_by(..., account_id: user.account_id)` →
   `Repo.get_by(..., account_id: current_membership.account_id)`
3. Channel `join` uses
   `current_membership.account_id == topic_account_id` (see
   `membership-scoped-channels`).

#### Scenario: Controller forwards to repo with membership account_id

- GIVEN `GET /api/calendar` with `current_membership.account_id = A`
- WHEN the controller calls
  `Calendar.monthly_overview(current_membership.account_id, ...)`
- THEN the repo filters by `account_id = A`; `Account_B` rows MUST NOT
  appear in the response

## Cross-References

`guardian-jwt-claims`, `multi-familia-switch-account`,
`membership-scoped-channels`, `account-membership`. Decision 5.1.