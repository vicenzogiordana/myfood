# Multi-Familia Switch Account Specification

> Reconstructed as-built on 2026-07-21 because the original was lost. Source: `design.md` §8.5, `AccountsMembership.switch_account/2`, `AccountLifecycleController.switch_account/2`, and `test/meal_planner_api_web/controllers/account_lifecycle_controller_test.exs`.

## Purpose

Defines the "switch account" flow: a User holding more than one membership
(multi-familia) can re-scope their active session to a different Account
they already belong to, without re-authenticating.

## Requirements

### Requirement: `switch_account/2` re-scopes to an owned, active membership

`AccountsMembership.switch_account(user, target_membership_id)` MUST: cast
the id to a UUID (`:membership_not_found` on failure); load the membership
and require `status == :active` (`:membership_not_active` otherwise,
`:membership_not_found` if no row); require `membership.user_id == user.id`
(`:not_your_membership` otherwise); re-fetch the User from the DB rather than
trusting the caller-supplied struct; and return
`{:ok, %{user, account, membership, claims}}`.

#### Scenario: Multi-familia User switches to a second active membership

- GIVEN a User with `:active` memberships on `Account_A` (current) and `Account_B`
- WHEN `switch_account(user, account_b_membership_id)` is called
- THEN it returns `{:ok, ...}` with `membership.account_id == Account_B.id` and `claims` scoped to `Account_B`

#### Scenario: Switch to another User's membership is refused

- GIVEN `target_membership_id` belongs to a different User
- WHEN `switch_account/2` is called
- THEN it returns `{:error, :not_your_membership}`

#### Scenario: Switch to a non-active membership is refused

- GIVEN `target_membership_id` resolves to a membership with `status: :invited` or `:suspended`
- WHEN `switch_account/2` is called
- THEN it returns `{:error, :membership_not_active}`

#### Scenario: Switch to an unknown membership id is refused

- GIVEN `target_membership_id` does not resolve to any row (or is malformed)
- WHEN `switch_account/2` is called
- THEN it returns `{:error, :membership_not_found}`

### Requirement: Claims for the switch are flag-gated

`switch_account/2`'s response `claims` MUST come from
`build_response_claims/3`, which mints `access_v2` (via
`AccountsMembership.claims_for/2`) only when `tenancy_v2_only?/0` is true,
and legacy `Accounts.claims_for/2` otherwise — mirroring
`accept_invite/2`'s minting rule (see `guardian-jwt-claims.md`).

#### Scenario: Flag off mints legacy claims on switch

- GIVEN `tenancy_v2_only?/0` is `false`
- WHEN `switch_account/2` succeeds
- THEN the returned `claims` come from `Accounts.claims_for/2` (no `typ: "access_v2"`)

### Requirement: HTTP surface has no `:account_id` in the URL

`POST /api/auth/switch-account` (body `{"membership_id": "<uuid>"}`) MUST be
piped through `:auth` only — `EnforceAccountScope` does not apply because
there is no `:account_id` path param. Errors map to
`403 not_your_membership`, `409 membership_not_active`,
`404 membership_not_found`.

#### Scenario: Successful switch returns a fresh auth payload

- GIVEN a multi-familia User authenticated with a JWT scoped to `Account_A`
- WHEN they call `POST /api/auth/switch-account` with a `membership_id` for `Account_B`
- THEN the response is `200` with a new `access_token` scoped to `Account_B`

#### Scenario: Switch to another User's membership returns 403

- WHEN `POST /api/auth/switch-account` is called with a `membership_id` owned by a different User
- THEN the response is `403 {"error":"not_your_membership"}`

#### Scenario: Switch to a suspended membership returns 409

- WHEN `POST /api/auth/switch-account` is called with a `membership_id` whose `status` is not `:active`
- THEN the response is `409 {"error":"membership_not_active"}`

### Requirement: End-to-end invite → accept → switch sequence

The full multi-familia journey (owner invites an email into Account A,
invitee accepts and later switches into a second membership on Account B)
MUST work without a forced re-login at any step.

#### Scenario: Owner invites, invitee accepts, invitee later switches

- GIVEN Owner(A) calls `POST /api/accounts/A/invites {email}` and receives a token
- WHEN Invitee calls `POST /api/invites/:token/accept` and later, after separately obtaining a 2nd membership on Account B, calls `POST /api/auth/switch-account {membership_id: B}`
- THEN each step succeeds and the final access token is scoped to Account B, with no re-authentication required between steps
