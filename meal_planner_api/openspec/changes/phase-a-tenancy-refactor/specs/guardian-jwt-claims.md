# Guardian JWT Claims Specification

> Reconstructed as-built on 2026-07-21 because the original was lost. Source: `design.md` §3, `MealPlannerApi.Auth.Guardian`, `Accounts.claims_for/2`, `AccountsMembership.claims_for/2`, `AuthController`, and `test/meal_planner_api/auth/guardian_test.exs`.
>
> **Reconstruction note (2026-07-21):** reconstructed as-built because the original spec was lost. The `MEAL_PLANNER_TENANCY_V2` → `:tenancy_v2_only` env→config binding in `config/runtime.exs` (trim/downcase, truthy set `true/1/yes/on`, fail-closed) lands via the separate `tenancy-v2-flag-wiring` change; the reader call sites are `Application.get_env(:meal_planner_api, :tenancy_v2_only, false)` in `accounts_membership.ex` and `auth_controller.ex`. Specs here describe that combined, wired state (consistent with `design.md` §9.1 / §11).

## Purpose

Defines the dual-write JWT claim shapes (`access` / `access_v1` and
`access_v2`) that Guardian verifies simultaneously, and the rules that decide
which shape is minted.

## Requirements

### Requirement: Guardian verifies both token types at all times

`MealPlannerApi.Auth.Guardian` MUST successfully `decode_and_verify` both
`typ: "access"` and `typ: "access_v2"` tokens signed with the app secret;
`subject_for_token/2` MUST always resolve to `user.id`.

#### Scenario: Both claim sets decode successfully

- GIVEN one JWT encoded with `token_type: "access"` and one with `token_type: "access_v2"` (including `membership_id`)
- WHEN both are decoded via `Guardian.decode_and_verify/2`
- THEN both succeed and each claim set matches its respective shape below

### Requirement: `access` (`access_v1`) claim shape

`Accounts.claims_for(user, account)` MUST return a map with `account_id`,
`account_type` (legacy compat string derived from `Account.plan`),
`subscription_tier`, `email`, `name`, `linked_user_ids`. It MUST NOT set
`typ` (Guardian stamps `typ: "access"` at encode time via `token_type:`).

#### Scenario: Legacy claim set matches the design shape

- GIVEN a User and an Account
- WHEN `Accounts.claims_for/2` builds the claim map
- THEN it contains exactly `account_id`, `account_type`, `subscription_tier`, `email`, `name`, `linked_user_ids` (plus Guardian's `sub`/`iat`/`exp`/`typ` added at sign time)

### Requirement: `access_v2` claim shape

`AccountsMembership.claims_for(user, membership)` MUST return a map with
`typ: "access_v2"`, `membership_id` (string), `account_id` (string), `role`
(string form of the enum), `plan` (string form, e.g. `"family_4"`), `status`
(string form), `email`, `name`.

#### Scenario: v2 claim set matches the design shape

- GIVEN a User and an `:active :owner` membership on a `:family_4` Account
- WHEN `AccountsMembership.claims_for/2` builds the claim map
- THEN `claims["typ"] == "access_v2"`, `claims["membership_id"] == to_string(membership.id)`, `claims["plan"] == "family_4"`, and `role`/`status` are string forms

### Requirement: `resource_from_claims/1` reattaches only two legacy fields

`Guardian.resource_from_claims/1` MUST re-attach `:subscription_tier` and
`:account_id` from the claims onto the loaded `%User{}`. It MUST NOT
re-attach `:account_type` (removed — `Account.plan`, surfaced via
`current_membership.plan`, is the source of truth).

#### Scenario: account_type is not reattached

- GIVEN a decoded claim set with a legacy `account_type` claim
- WHEN `resource_from_claims/1` loads the User
- THEN the returned struct carries `subscription_tier` and `account_id` from the claims but no `account_type` override

### Requirement: Minting is gated by the `tenancy_v2_only` flag

`Application.get_env(:meal_planner_api, :tenancy_v2_only, false)` MUST
default to `false` (fail-closed) when unset. `AuthController.password/2`,
`Accounts.authenticate_with_password/1`, `AccountsMembership.accept_invite/2`,
and `AccountsMembership.switch_account/2` MUST mint `access` when the flag is
`false` and `access_v2` (via the canonical claims builder) when `true`.
`AuthController.issuance_typ/1` MUST fall back to `:access` (never crash)
when the flag is on but no real `%AccountMembership{}` is available.

#### Scenario: Flag off mints access_v1 (regression)

- GIVEN `Application.get_env(:meal_planner_api, :tenancy_v2_only)` is `false` (the default)
- WHEN a User registers or logs in via `POST /api/auth/password`
- THEN the minted access token has `typ: "access"`

#### Scenario: Flag on mints access_v2

- GIVEN the flag is set to `true`
- WHEN a User registers or logs in
- THEN the minted access token has `typ: "access_v2"` with a `membership_id` claim

#### Scenario: Env var drives the flag at boot (fail-closed)

- GIVEN a deployed environment setting `MEAL_PLANNER_TENANCY_V2` to a truthy value (`true`, `1`, `yes`, or `on`, case- and whitespace-insensitive)
- WHEN the application boots (`config/runtime.exs`, non-`:test` environments)
- THEN `Application.get_env(:meal_planner_api, :tenancy_v2_only, false)` returns `true`
- AND any other value (unset, `false`, `0`, `no`, `off`, or unrecognized) resolves to `false`, so a mistyped operator value never silently enables v2

### Requirement: Refresh preserves the original `typ`

`AuthController.refresh/2` MUST reissue whatever `typ` the incoming refresh
token's claims imply (`membership_id` present → `access_v2`, else
`access_v1`), independent of the current flag value, and MUST require
`claims["typ"] == "refresh"` explicitly (Guardian does not enforce
`token_type:` at decode time).

#### Scenario: Refresh of an access_v2-derived token stays v2

- GIVEN a refresh token whose claims include `membership_id`
- WHEN `POST /api/auth/refresh` is called, regardless of the current flag value
- THEN the reissued access token has `typ: "access_v2"`

#### Scenario: Wrong-typ refresh token is rejected

- GIVEN a token with `typ` other than `"refresh"` (or missing `typ`) presented as `refresh_token`
- WHEN `POST /api/auth/refresh` is called
- THEN the response is `401 {"error":"invalid_refresh_token"}`
