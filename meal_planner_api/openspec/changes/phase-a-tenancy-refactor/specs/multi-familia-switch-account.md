# Multi-Familia: Switch Account

## Purpose

Defines how an authenticated `User` who holds N `:active` memberships
switches the active Account and obtains a freshly scoped JWT. Per
`context.md` §4 the "Spotify Family for meal plans" model — each person
keeps their own login, the active account is determined by the JWT,
switching = re-issue the JWT.

**Grill decisions referenced**: `context.md` §3 (no take-over, no transfer),
§4 (User holds N memberships, JWT carries `membership_id`),
proposal §"Approach — Feature flag" (env-var flip is the only cutover step).

## Requirements

### Requirement: Switch endpoint re-issues the JWT

`POST /api/auth/switch-account` MUST accept `{ "membership_id": "<uuid>" }`
and MUST:

1. Look up the membership by id.
2. Verify the JWT subject User is the membership's `user_id` — no take-over.
3. Verify `membership.status == :active`.
4. Re-issue `access_token` + `refresh_token` with `typ: "access_v2"`,
   `membership_id`, `account_id`, `role`, `plan` claims (see
   `guardian-jwt-claims`).
5. Return the new tokens and the serialized membership.

#### Scenario: User switches to a second Account

- GIVEN `User_U` is `:active` in `Account_A` (`:owner`) and `Account_B`
  (`:member`), currently scoped to `Account_A`
- WHEN `User_U` calls `POST /api/auth/switch-account` with
  `{ "membership_id": "<B-id>" }`
- THEN the new `access_token` carries `membership_id = <B-id>` and
  `account_id = Account_B.id`; `current_membership.account_id` resolves to
  `Account_B.id`

#### Scenario: Switch to a non-owned membership is rejected

- GIVEN the JWT subject is `User_U`
- WHEN the body is `{ "membership_id": "<User_X-id>" }` for a membership
  belonging to `User_X`
- THEN the response is `403 not_your_membership` and no token is minted

#### Scenario: Switch to a suspended membership is rejected

- GIVEN `User_U` has a membership in `Account_C` with `status: :suspended`
- WHEN the body references that membership
- THEN the response is `409 membership_not_active`

#### Scenario: User with one membership is a no-op

- GIVEN `User_U` holds exactly one `:active` membership
- WHEN the call references that same membership id
- THEN the response is `200` with a freshly minted token (so callers can
  rely on a uniform post-switch shape)

### Requirement: Cross-Account isolation after switch

After a switch, every read and write through the new JWT MUST be scoped to
`membership.account_id` and MUST NOT leak data from any other Account the
User holds a membership in. The pipeline MUST reject requests where the URL
`:account_id` does not match the JWT `account_id` claim (see
`auth-pipeline-and-current-resource`).

#### Scenario: Multi-familia cross-Account leak is prevented

- GIVEN `User_U` is `:active` in `Account_A` and `Account_B`, JWT scoped
  to `Account_A`
- WHEN `User_U` calls `GET /api/accounts/<Account_B_id>/memberships`
- THEN the pipeline rejects with `403 account_mismatch` before the
  controller runs, even though `User_U` legitimately belongs to `Account_B`

#### Scenario: Switch refreshes WS authorization

- GIVEN `User_U` connected to `"planning:<Account_A_id>"` with a JWT scoped
  to `Account_A`
- WHEN `User_U` calls `POST /api/auth/switch-account` to `Account_B` and
  reconnects the socket with the new JWT
- THEN the join of `"planning:<Account_B_id>"` MUST be accepted and the
  prior socket is closed; joining `"planning:<Account_A_id>"` with the new
  JWT MUST be rejected (account-mismatch)

## Cross-References

`auth-pipeline-and-current-resource`, `guardian-jwt-claims`,
`membership-scoped-channels`, `account-membership`. Grill 2026-06-16
"no take-over" enforced here.