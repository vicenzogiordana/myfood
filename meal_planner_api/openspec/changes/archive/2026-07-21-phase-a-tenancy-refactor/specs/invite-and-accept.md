# Invite and Accept Specification

> Reconstructed as-built on 2026-07-21 because the original was lost. Source: `design.md` §6, `AccountsMembership.invite/3` + `accept_invite/2` + `list_memberships/1` + `remove_member/3` + `leave/2`, `Services.InviteService`, `InviteController`, `MembershipController`, `AccountLifecycleController.leave/2`.

## Purpose

Defines the invitation lifecycle (owner invites an email → invitee accepts),
the membership roster, and the owner-removes / member-leaves flows.

## Requirements

### Requirement: `invite/3` is owner-only and seat-cap enforced

`AccountsMembership.invite/3` MUST refuse a non-`:owner` actor with
`{:error, :not_owner}`, MUST run inside a transaction holding
`SELECT … FOR UPDATE` on the Account row, MUST enforce the seat cap before
inserting, and MUST refuse a duplicate invite (`:already_invited` for an
existing `:invited` row, `:already_a_member` for an existing `:active` row).

#### Scenario: Owner successfully invites an email

- GIVEN an `:owner` membership on an Account under its seat cap
- WHEN `invite(account, owner_membership, "new@example.com")` is called
- THEN it returns `{:ok, %{token, expires_at, membership_id, email}}` with the plaintext token returned exactly once

#### Scenario: Non-owner cannot invite

- GIVEN a `:member` actor
- WHEN `invite/3` is called with that actor
- THEN it returns `{:error, :not_owner}`

#### Scenario: Fifth invite on a full family_4 Account is refused

- GIVEN a `:family_4` Account already at 4 `:active + :invited` rows
- WHEN the owner invites a 5th email
- THEN `invite/3` returns `{:error, :seat_cap_reached}`

### Requirement: Invite token model

`InviteService.mint_token/0` MUST produce a plaintext of 32 random bytes
URL-safe base64-encoded without padding (~43 chars) and a SHA-256 lower-hex
hash (64 chars); only the hash MUST be persisted. Expiry MUST be 7 days from
mint.

#### Scenario: Mint produces the expected shapes

- GIVEN a call to `mint_token/0`
- WHEN the result is inspected
- THEN the plaintext is at least 40 chars and the hash is 64 lower-case hex chars

### Requirement: `accept_invite/2` flips `:invited → :active`

`AccountsMembership.accept_invite/2` MUST support both an existing
`%User{}` argument and a new-user `%{name, password_hash}` map. On success it
MUST set `status: :active`, `joined_at`, and `user_id` (pointing at the
invitee), and return `{:ok, %{user, account, membership, claims}}` where
`claims` comes from the flag-gated `build_response_claims/3`.

#### Scenario: Existing User accepts

- GIVEN a valid `:invited` plaintext token and an existing `%User{}`
- WHEN `accept_invite(plaintext, existing_user)` is called
- THEN the membership flips to `:active`, `joined_at` is set, and claims are returned

#### Scenario: New User accepts

- GIVEN a valid `:invited` plaintext token and `%{name: "...", password_hash: "..."}`
- WHEN `accept_invite/2` is called
- THEN the stub User created at invite time is filled in with `name`/`password_hash` and the membership flips to `:active`

### Requirement: Invite token replay/expiry detection (columns retained)

Unlike the original task description, the shipped code MUST NOT null
`invite_token_hash` / `invite_expires_at` on accept. Single-use replay
detection MUST rely on `status != :invited` (returns `:invite_token_used`).
An unmatched hash MUST return `:invite_token_unknown`; a matched-but-expired
row MUST return `:invite_token_expired`.

#### Scenario: Replay after accept is rejected

- GIVEN a membership already flipped to `:active` by a prior `accept_invite/2` call
- WHEN the same plaintext token is submitted again
- THEN the result is `{:error, :invite_token_used}` (the row's hash/expiry columns are still present, only `status` differs)

#### Scenario: Expired token is rejected

- GIVEN an `:invited` row whose `invite_expires_at` is in the past
- WHEN `accept_invite/2` is called with its plaintext
- THEN the result is `{:error, :invite_token_expired}`

### Requirement: Membership roster ordering

`AccountsMembership.list_memberships/1` MUST return `:active` and `:invited`
rows (excluding `:suspended`) ordered owner-first, then by `joined_at`, then
`inserted_at`, preloading `:user`.

#### Scenario: Roster lists owner first

- GIVEN an Account with one `:owner` and two `:member` rows
- WHEN `list_memberships/1` is called
- THEN the owner row is first in the result list

### Requirement: Owner-only hard-delete of a member

`AccountsMembership.remove_member/3` MUST refuse a non-owner actor
(`:not_owner`), refuse removing the owner (`:cannot_remove_owner`), and
otherwise hard-delete the target's membership row.

#### Scenario: Owner removes a member

- GIVEN an owner actor and a `:member` target on the same Account
- WHEN `remove_member(account, target_user_id, owner_actor)` is called
- THEN the membership row is deleted and `:ok` is returned

#### Scenario: Owner cannot remove themselves

- GIVEN an owner actor targeting their own `user_id`
- WHEN `remove_member/3` is called
- THEN it returns `{:error, :cannot_remove_owner}`

### Requirement: Member self-leave refuses the owner

`AccountsMembership.leave/2` MUST look the actor's row up by
`(user_id, account_id)` (not `actor.id`), return `:not_a_member` if no row
exists for that Account, and refuse an `:owner` actor with
`:cannot_leave_owned_account`.

#### Scenario: Member leaves successfully

- GIVEN a `:member` actor
- WHEN `leave(account, actor)` is called
- THEN the membership is hard-deleted and `:ok` is returned

#### Scenario: Owner cannot leave their own Account

- GIVEN an `:owner` actor
- WHEN `leave/2` is called
- THEN it returns `{:error, :cannot_leave_owned_account}`

### Requirement: HTTP surface and error mapping

`InviteController`, `MembershipController`, and
`AccountLifecycleController.leave/2` MUST expose:
`POST /api/accounts/:account_id/invites` (`201`, errors `403 not_owner`,
`409 seat_cap_reached/already_invited/already_a_member`),
`POST /api/invites/:token/accept` (`200` full auth payload, errors
`410 invite_token_used/invite_token_expired`, `404 invite_token_unknown`),
`GET .../memberships` (`200`, `404 account_not_found` for non-members),
`DELETE .../memberships/:user_id` (`204`, `403 not_owner/cannot_remove_owner`,
`404 membership_not_found`), `POST .../leave` (`204`,
`403 cannot_leave_owned_account`, `404 not_a_member`).

#### Scenario: Accept route is not behind :auth

- GIVEN a brand-new invitee with no prior session
- WHEN they call `POST /api/invites/:token/accept` with `{"name", "password"}`
- THEN the request succeeds without any Authorization header (the route is `:api`-only, per design §5.2)

#### Scenario: Non-owner invite create returns 403

- GIVEN a `:member`-role caller
- WHEN they call `POST /api/accounts/:account_id/invites`
- THEN the response is `403 {"error":"not_owner"}`
