# Auth Pipeline & Current Resource Specification

> Reconstructed as-built on 2026-07-21 because the original was lost. Source: `design.md` §4, `MealPlannerApiWeb.AuthPipeline`, `Plugs.VerifyTokenType`, `Plugs.LoadCurrentMembership`, `Plugs.EnforceAccountScope`, and their test suites.

## Purpose

Defines the `:auth` Plug pipeline that verifies a Bearer JWT and populates
`conn.assigns.current_user` and `conn.assigns.current_membership`, plus the
`EnforceAccountScope` plug that guards `:account_id`-bearing routes. This is
the HTTP-side twin of `membership-scoped-channels.md` (the WebSocket side).

## Requirements

### Requirement: `:auth` pipeline order

The `:auth` pipeline MUST run, in order: `Guardian.Plug.VerifyHeader` (no
`typ` filter) → `VerifyTokenType` → `Guardian.Plug.EnsureAuthenticated` →
`Guardian.Plug.LoadResource(allow_blank: false)` → `LoadCurrentMembership`.

#### Scenario: access_v1 token verifies and reaches the controller

- GIVEN a valid `access` (`access_v1`) Bearer token
- WHEN a request hits an `:auth`-piped route
- THEN the pipeline passes and `conn.assigns.current_user` is populated

#### Scenario: access_v2 token verifies and populates current_membership

- GIVEN a valid `access_v2` Bearer token with a real `membership_id`
- WHEN a request hits an `:auth`-piped route
- THEN `conn.assigns.current_membership.id` equals that membership's id

### Requirement: `VerifyTokenType` rejects unsupported `typ`

`VerifyTokenType` MUST accept only `claims["typ"] in ~w(access access_v2)`
and halt any other value with `401 {"error":"unsupported_token_type"}`. The
supported set MUST be exposed via `VerifyTokenType.supported_typs/0` for
out-of-pipeline decoders (e.g. `InviteController.resolve_invitee/2`).

#### Scenario: Unknown typ halts the request

- GIVEN a validly-signed token with `typ: "access_v3"`
- WHEN it is presented to an `:auth`-piped route
- THEN the response is `401 {"error":"unsupported_token_type"}`

### Requirement: `LoadCurrentMembership` requires a real `:active` row

For BOTH `access_v2` and legacy `access` tokens, `LoadCurrentMembership` MUST
resolve `current_membership` to a genuine `AccountMembership` database row.
There is NO in-memory synthesized membership in the shipped code. A missing
row, a missing/blank `membership_id`, or (for `access_v2`) a non-`:active`
row MUST halt with `401 {"error":"membership_id_required"}`.

#### Scenario: access_v2 with no membership_id is denied

- GIVEN an `access_v2` token whose claims omit `membership_id`
- WHEN it reaches `LoadCurrentMembership`
- THEN the response is `401 {"error":"membership_id_required"}`

#### Scenario: Legacy token with no active membership is denied

- GIVEN a legacy `access` token for a User who was removed from their Account (membership hard-deleted)
- WHEN the token (still within its TTL) is presented
- THEN `AccountMembershipQueries.load_active_membership/3` finds no row and the request is denied with `401 {"error":"membership_id_required"}`

#### Scenario: Legacy token resolves to the real active membership

- GIVEN a legacy `access` token for a User who still holds an `:active` membership on `claims["account_id"]`
- WHEN it reaches `LoadCurrentMembership`
- THEN `conn.assigns.current_membership` is that real row (never a synthesized struct)

### Requirement: `EnforceAccountScope` guards `:account_id` routes only

`EnforceAccountScope` MUST run after `LoadCurrentMembership` and, only for
routes carrying an `:account_id` path param, halt with
`403 {"error":"account_mismatch"}` when
`conn.path_params["account_id"] != current_membership.account_id`. Routes
without `:account_id` in the URL (e.g. `POST /api/auth/switch-account`) MUST
be a no-op for this plug.

#### Scenario: URL/JWT account mismatch is rejected

- GIVEN a JWT scoped to `Account_A` and a request to `GET /api/accounts/:account_id/memberships` with `account_id = Account_B.id`
- WHEN the request passes through `EnforceAccountScope`
- THEN the response is `403 {"error":"account_mismatch"}`

#### Scenario: Matching URL and JWT proceeds

- GIVEN a JWT scoped to `Account_A` and a request to `.../accounts/:account_id/memberships` with `account_id = Account_A.id`
- WHEN the request passes through `EnforceAccountScope`
- THEN the request reaches the controller

#### Scenario: Route with no `:account_id` param is unaffected

- GIVEN `POST /api/auth/switch-account` (no `:account_id` path param)
- WHEN the request passes through the pipeline
- THEN `EnforceAccountScope` performs no check and the request proceeds

### Requirement: Controllers/services read `current_membership.account_id`

Every tenancy-scoped controller, repo query module, and service MUST resolve
the Account from `conn.assigns.current_membership.account_id` (or the
service-layer equivalent), never `current_user.account_id`, except inside
`LoadCurrentMembership`'s own legacy-token resolution step.

#### Scenario: Cross-Account isolation via current_membership

- GIVEN a multi-familia User with an `:owner` membership in `Account_A` and a `:member` membership in `Account_B`, holding a JWT scoped to `Account_A`
- WHEN they call `GET /api/calendar` (no `:account_id` in the URL)
- THEN only `Account_A` data is returned
