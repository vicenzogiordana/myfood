# Guardian JWT Claims

## Purpose

Defines the JWT claim shape that `MealPlannerApi.Auth.Guardian` mints and
verifies, and how the dual-write feature flag (`access_v1` vs `access_v2`)
governs the cutover without forcing a mobile release.

This spec is **MODIFIED** — current behavior (read from
`meal_planner_api/lib/meal_planner_api/auth/guardian.ex` and
`auth_controller.ex`) is preserved as the `access_v1` path; the new behavior
is the `access_v2` path described below.

**Grill decisions referenced**: `context.md` §4 (JWT carries `account_id` +
`membership_id`), proposal §"Approach — Feature flag" (only the env-var
flip is the cutover step).

## Current Behavior (pre-Phase A)

`Guardian.resource_from_claims/1` reads `sub` (User.id), re-attaches
`:account_type`, `:subscription_tier`, and `:account_id` from claims. Token
type is `"access"` (via `Guardian.Plug.VerifyHeader, claims: %{"typ" =>
"access"}`). No `membership_id` claim exists. Controllers and channels
read tenancy from `current_user.account_id`.

`Accounts.claims_for/2` builds
`%{account_id, account_type, subscription_tier, email, name,
linked_user_ids}` — no `membership_id`.

## New Behavior (Phase A)

### Requirement: Two JWT types via the `typ` claim

The system MUST mint and verify JWTs whose `typ` claim is one of:

| `typ`        | Issued when                                       | Tenancy source                  |
|--------------|---------------------------------------------------|---------------------------------|
| `"access"`   | `MEAL_PLANNER_TENANCY_V2=false` (default, legacy) | `user.account_id`               |
| `"access_v2"`| `MEAL_PLANNER_TENANCY_V2=true`                    | `membership.account_id`         |

Both MUST be acceptable to `AuthPipeline` during the cutover window; the
pipeline MUST dispatch on `typ` (see `auth-pipeline-and-current-resource`).

#### Scenario: Mint an access_v2 token after registration

- GIVEN `MEAL_PLANNER_TENANCY_V2=true` and a successful
  `register_with_password` call
- WHEN `AuthController.password/2` returns the auth payload
- THEN `access_token` and `refresh_token` carry `typ: "access_v2"` with the
  claim set below; the response payload includes the serialized `membership`

#### Scenario: Reject an unknown `typ`

- GIVEN a JWT whose `typ` is neither `"access"` nor `"access_v2"`
- WHEN `AuthPipeline.VerifyHeader` runs
- THEN the response is `401 unauthorized` with
  `reason: "unsupported_token_type"`

### Requirement: access_v2 claim shape

An `access_v2` JWT MUST include:

| Claim           | Type    | Source                                         |
|-----------------|---------|------------------------------------------------|
| `sub`           | string  | `User.id`                                      |
| `typ`           | string  | `"access_v2"`                                  |
| `membership_id` | string  | `AccountMembership.id`                         |
| `account_id`    | string  | `AccountMembership.account_id`                 |
| `role`          | string  | `AccountMembership.role` (`"owner"`/`"member"`)|
| `plan`          | string  | `Account.plan`                                 |
| `status`        | string  | `AccountMembership.status`                     |
| `email`         | string  | `User.email`                                   |
| `name`          | string  | `User.name`                                    |
| `exp` / `iat`   | integer | Guardian defaults                              |

#### Scenario: Refresh produces the same claim set

- GIVEN an `access_v2` refresh token presented to `POST /api/auth/refresh`
- WHEN the controller validates and re-issues
- THEN the new token MUST carry the same `membership_id`, `account_id`,
  `role`, `plan`, and `status` (no silent re-scoping)

#### Scenario: Missing membership_id in an access_v2 token

- GIVEN a token presented as `typ: "access_v2"` but lacking `membership_id`
- WHEN the pipeline decodes it
- THEN the response is `401 unauthorized` with
  `reason: "membership_id_required"` — partial access_v2 tokens are not
  accepted

### Requirement: Dual-write feature flag

The system MUST read `MEAL_PLANNER_TENANCY_V2` at boot. The flag controls
**issuance only**:

- `false` → `AuthController` mints `typ: "access"` via
  `Accounts.claims_for/2`.
- `true` → `AuthController` mints `typ: "access_v2"` via
  `AccountsMembership.claims_for/2`.

The flag MUST NOT change the verification path: `AuthPipeline.VerifyHeader`
accepts both `typ` values. The flag is the **only** cutover step — no DB
migration, no forced logout, no mobile release.

#### Scenario: Flip the flag, keep both clients working

- GIVEN a deployment with `MEAL_PLANNER_TENANCY_V2=false`
- WHEN the operator flips it to `true` and the API restarts
- THEN legacy `typ: "access"` tokens are still verified; new tokens are
  minted as `typ: "access_v2"`; mobile clients keep working without an app
  update

#### Scenario: Flip back the flag

- GIVEN `MEAL_PLANNER_TENANCY_V2=true` issuing `access_v2`
- WHEN the operator flips it to `false` and the API restarts
- THEN new tokens are minted as `typ: "access"`; existing `access_v2`
  tokens continue to verify until TTL — no forced logout

## Cross-References

`auth-pipeline-and-current-resource`, `multi-familia-switch-account`.
Decisions 5.1, 5.4.