# Auth Capability Specification

> **Source**: `phase-a-tenancy-refactor` change. Merged from delta specs: `auth-pipeline-and-current-resource.md`, `guardian-jwt-claims.md`.
> **Date**: 2026-07-21 (Phase A archive)

## Purpose

Defines the HTTP authentication pipeline that verifies Bearer JWTs, the dual-write JWT claim shapes (`access_v1` and `access_v2`), and the account-scoping plug that guards routes.

---

## JWT Claim Shapes

### Requirement: Guardian verifies both token types at all times

`MealPlannerApi.Auth.Guardian` MUST successfully `decode_and_verify` both `typ: "access"` and `typ: "access_v2"` tokens signed with the app secret; `subject_for_token/2` MUST always resolve to `user.id`.

#### Scenario: Both claim sets decode successfully

- GIVEN one JWT encoded with `token_type: "access"` and one with `token_type: "access_v2"` (including `membership_id`)
- WHEN both are decoded via `Guardian.decode_and_verify/2`
- THEN both succeed and each claim set matches its respective shape below

### Requirement: `access` (`access_v1`) claim shape

`Accounts.claims_for(user, account)` MUST return a map with `account_id`, `account_type` (legacy compat string derived from `Account.plan`), `subscription_tier`, `email`, `name`, `linked_user_ids`. It MUST NOT set `typ` (Guardian stamps `typ: "access"` at encode time via `token_type:`).

#### Scenario: Legacy claim set matches design shape

- GIVEN a User and an Account
- WHEN `Accounts.claims_for/2` builds the claim map
- THEN it contains exactly `account_id`, `account_type`, `subscription_tier`, `email`, `name`, `linked_user_ids`

### Requirement: `access_v2` claim shape

`AccountsMembership.claims_for(user, membership)` MUST return a map with `typ: "access_v2"`, `membership_id` (string), `account_id` (string), `role` (string form of the enum), `plan` (string form, e.g. `"family_4"`), `status` (string form), `email`, `name`.

#### Scenario: v2 claim set matches design shape

- GIVEN a User and an `:active :owner` membership on a `:family_4` Account
- WHEN `AccountsMembership.claims_for/2` builds the claim map
- THEN `claims["typ"] == "access_v2"`, `claims["membership_id"] == to_string(membership.id)`, `claims["plan"] == "family_4"`

### Requirement: `resource_from_claims/1` reattaches legacy fields only

`Guardian.resource_from_claims/1` MUST re-attach `:subscription_tier` and `:account_id` from claims onto the loaded `%User{}`. It MUST NOT re-attach `:account_type` (removed — `Account.plan` is the source of truth).

### Requirement: Minting is gated by the `tenancy_v2_only` flag

`Application.get_env(:meal_planner_api, :tenancy_v2_only, false)` MUST default to `false` (fail-closed). `AuthController.password/2`, `Accounts.authenticate_with_password/1`, `AccountsMembership.accept_invite/2`, and `AccountsMembership.switch_account/2` MUST mint `access` when the flag is `false` and `access_v2` when `true`.

#### Scenario: Flag off mints access_v1 (regression)

- GIVEN `Application.get_env(:meal_planner_api, :tenancy_v2_only)` is `false`
- WHEN a User registers or logs in
- THEN the minted access token has `typ: "access"`

#### Scenario: Flag on mints access_v2

- GIVEN the flag is set to `true`
- WHEN a User registers or logs in
- THEN the minted access token has `typ: "access_v2"` with a `membership_id` claim

#### Scenario: Env var drives the flag (fail-closed)

- GIVEN a deployed environment setting `MEAL_PLANNER_TENANCY_V2` to a truthy value (`true`, `1`, `yes`, or `on`, case- and whitespace-insensitive)
- WHEN the application boots
- THEN `Application.get_env(:meal_planner_api, :tenancy_v2_only, false)` returns `true`
- AND any other value resolves to `false`, so a mistyped operator value never silently enables v2

### Requirement: Refresh preserves the original `typ`

`AuthController.refresh/2` MUST reissue whatever `typ` the incoming refresh token's claims imply (`membership_id` present → `access_v2`, else `access_v1`), independent of the current flag value, and MUST require `claims["typ"] == "refresh"` explicitly.

#### Scenario: Refresh of an access_v2-derived token stays v2

- GIVEN a refresh token whose claims include `membership_id`
- WHEN `POST /api/auth/refresh` is called
- THEN the reissued access token has `typ: "access_v2"`

---

## HTTP Auth Pipeline

### Requirement: `:auth` pipeline order

The `:auth` pipeline MUST run, in order: `Guardian.Plug.VerifyHeader` (no `typ` filter) → `VerifyTokenType` → `Guardian.Plug.EnsureAuthenticated` → `Guardian.Plug.LoadResource(allow_blank: false)` → `LoadCurrentMembership`.

#### Scenario: access_v1 token verifies and reaches the controller

- GIVEN a valid `access` (`access_v1`) Bearer token
- WHEN a request hits an `:auth`-piped route
- THEN the pipeline passes and `conn.assigns.current_user` is populated

#### Scenario: access_v2 token verifies and populates current_membership

- GIVEN a valid `access_v2` Bearer token with a real `membership_id`
- WHEN a request hits an `:auth`-piped route
- THEN `conn.assigns.current_membership.id` equals that membership's id

### Requirement: `VerifyTokenType` rejects unsupported `typ`

`VerifyTokenType` MUST accept only `claims["typ"] in ~w(access access_v2)` and halt any other value with `401 {"error":"unsupported_token_type"}`. The supported set MUST be exposed via `VerifyTokenType.supported_typs/0`.

#### Scenario: Unknown typ halts the request

- GIVEN a validly-signed token with `typ: "access_v3"`
- WHEN it is presented to an `:auth`-piped route
- THEN the response is `401 {"error":"unsupported_token_type"}`

### Requirement: `LoadCurrentMembership` requires a real `:active` row

For BOTH `access_v2` and legacy `access` tokens, `LoadCurrentMembership` MUST resolve `current_membership` to a genuine `AccountMembership` database row. There is NO in-memory synthesized membership. A missing row or non-`:active` status MUST halt with `401 {"error":"membership_id_required"}`.

#### Scenario: access_v2 with no membership_id is denied

- GIVEN an `access_v2` token whose claims omit `membership_id`
- WHEN it reaches `LoadCurrentMembership`
- THEN the response is `401 {"error":"membership_id_required"}`

#### Scenario: Legacy token resolves to the real active membership

- GIVEN a legacy `access` token for a User with a real `:active` membership
- WHEN it reaches `LoadCurrentMembership`
- THEN `conn.assigns.current_membership` is that real row

### Requirement: `EnforceAccountScope` guards `:account_id` routes only

`EnforceAccountScope` MUST run after `LoadCurrentMembership` and, only for routes carrying an `:account_id` path param, halt with `403 {"error":"account_mismatch"}` when `conn.path_params["account_id"] != current_membership.account_id`.

#### Scenario: URL/JWT account mismatch is rejected

- GIVEN a JWT scoped to `Account_A` and a request with `account_id = Account_B.id`
- WHEN the request passes through `EnforceAccountScope`
- THEN the response is `403 {"error":"account_mismatch"}`

### Requirement: Controllers/services read `current_membership.account_id`

Every tenancy-scoped controller, repo query module, and service MUST resolve the Account from `conn.assigns.current_membership.account_id`, never `current_user.account_id`, except inside `LoadCurrentMembership`'s own legacy-token resolution step.
