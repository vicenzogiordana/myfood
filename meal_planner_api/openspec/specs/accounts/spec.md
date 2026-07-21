# Accounts Capability Specification

> **Source**: `phase-a-tenancy-refactor` change. Merged from delta specs: `account-membership.md`, `invite-and-accept.md`, `multi-familia-switch-account.md`.
> **Date**: 2026-07-21 (Phase A archive)

## Purpose

Defines multi-tenant account membership, invitation lifecycle, and multi-familia account switching. Replaces the single-tenant `users.account_id` model with a join entity `AccountMembership` that is the sole source of truth for tenancy.

---

## Requirements

### Requirement: `account_memberships` table shape

The system MUST persist tenancy membership as rows in `account_memberships` with `account_id`, `user_id`, `role` (`owner|member`), `status` (`active|invited|suspended`), `invited_by_user_id`, `invite_token_hash`, `invite_expires_at`, `joined_at`. `role` and `status` MUST be CHECK-constrained at the DB level in addition to `Ecto.Enum` validation.

#### Scenario: Exactly one active membership per (account, user)

- GIVEN an `:active` membership already exists for `(account_id, user_id)`
- WHEN a second `:active` row is inserted for the same pair
- THEN the partial unique index `account_memberships_active_account_user_unique_index` raises `unique_violation`

#### Scenario: Invalid role or status rejected

- GIVEN a changeset with `role: :admin` or `status: :pending`
- WHEN `AccountMembership.changeset/2` validates it
- THEN the changeset is invalid (enum inclusion failure)

### Requirement: `Account.plan` replaces `account_type`

The system MUST resolve every Account to exactly one `plan` value (`individual | family_4 | family_6 | trial`); the legacy `:group | :individual` `account_type` enum MUST NOT exist post-migration.

#### Scenario: Legacy `:group` accounts become `family_4`

- GIVEN a pre-Phase-A account with `account_type: :group`
- WHEN migration `20260625000002_alter_accounts_to_plan_enum` runs
- THEN the account's `plan` is `:family_4` and the `account_type` column no longer exists

### Requirement: Backfill invariants enforced in-transaction

The system MUST backfill one `:active` membership per legacy `(users.id, users.account_id)` pair and MUST refuse to complete the migration if `check_account_membership_invariants()` finds any Account without exactly one `:active :owner` membership.

### Requirement: Seat cap resolved from `Account.plan`

`AccountsMembership.seat_usage/1` MUST count `:active + :invited` rows for an Account and compare against the plan's capacity (`individual: 1, family_4: 4, family_6: 6, trial: 6`).

#### Scenario: Seat cap reached on `family_4`

- GIVEN an Account on `:family_4` with 4 `:active` memberships
- WHEN `enforce_seat_cap(account, 1)` is called
- THEN it returns `{:error, :seat_cap_reached}`

### Requirement: Atomic registration creates the owner membership

`Accounts.register_with_password/1` MUST create the Account, the User, and one `:owner :active` membership in a single `Ecto.Multi` transaction; any step failing MUST roll back the entire registration (no orphan Account or User).

### Requirement: `users.role` and `account_id` retained for dual-write window

`users.account_id` MUST be nullable and `users.role` MUST remain on the `User` schema during Phase A (feeds legacy compatibility and the backfill role default).

---

## Invitation Lifecycle

### Requirement: `invite/3` is owner-only and seat-cap enforced

`AccountsMembership.invite/3` MUST refuse a non-`:owner` actor with `{:error, :not_owner}`, MUST run inside a transaction holding `SELECT … FOR UPDATE` on the Account row, MUST enforce the seat cap before inserting, and MUST refuse a duplicate invite.

#### Scenario: Owner successfully invites an email

- GIVEN an `:owner` membership on an Account under its seat cap
- WHEN `invite(account, owner_membership, "new@example.com")` is called
- THEN it returns `{:ok, %{token, expires_at, membership_id, email}}` with the plaintext token returned exactly once

### Requirement: Invite token model (plaintext + hash)

`InviteService.mint_token/0` MUST produce a plaintext of 32 random bytes URL-safe base64-encoded without padding (~43 chars) and a SHA-256 lower-hex hash (64 chars); only the hash MUST be persisted. Expiry MUST be 7 days from mint.

### Requirement: `accept_invite/2` flips `:invited → :active`

`AccountsMembership.accept_invite/2` MUST support both an existing `%User{}` argument and a new-user `%{name, password_hash}` map. On success it MUST set `status: :active`, `joined_at`, and `user_id`.

#### Scenario: Existing User accepts

- GIVEN a valid `:invited` plaintext token and an existing `%User{}`
- WHEN `accept_invite(plaintext, existing_user)` is called
- THEN the membership flips to `:active`, `joined_at` is set, and claims are returned

### Requirement: Invite token replay/expiry detection (columns retained)

Single-use replay detection MUST rely on `status != :invited` (returns `:invite_token_used`). An unmatched hash MUST return `:invite_token_unknown`; a matched-but-expired row MUST return `:invite_token_expired`.

### Requirement: Membership roster ordering

`AccountsMembership.list_memberships/1` MUST return `:active` and `:invited` rows ordered owner-first, then by `joined_at`, then `inserted_at`, preloading `:user`.

### Requirement: Owner-only hard-delete of a member

`AccountsMembership.remove_member/3` MUST refuse a non-owner actor (`:not_owner`), refuse removing the owner (`:cannot_remove_owner`), and otherwise hard-delete the target's membership row.

### Requirement: Member self-leave refuses the owner

`AccountsMembership.leave/2` MUST look the actor's row up by `(user_id, account_id)`, return `:not_a_member` if no row exists, and refuse an `:owner` actor with `:cannot_leave_owned_account`.

---

## Multi-Familia Account Switching

### Requirement: `switch_account/2` re-scopes to an owned, active membership

`AccountsMembership.switch_account(user, target_membership_id)` MUST: cast the id to a UUID (`:membership_not_found` on failure); load the membership and require `status == :active` (`:membership_not_active` otherwise); require `membership.user_id == user.id` (`:not_your_membership` otherwise); re-fetch the User from the DB; and return `{:ok, %{user, account, membership, claims}}`.

#### Scenario: Multi-familia User switches to a second active membership

- GIVEN a User with `:active` memberships on `Account_A` (current) and `Account_B`
- WHEN `switch_account(user, account_b_membership_id)` is called
- THEN it returns `{:ok, ...}` with `membership.account_id == Account_B.id` and `claims` scoped to `Account_B`

### Requirement: Claims for the switch are flag-gated

The response `claims` MUST come from `build_response_claims/3`, which mints `access_v2` only when `tenancy_v2_only?/0` is true, and legacy `Accounts.claims_for/2` otherwise.

### Requirement: HTTP surface (no `:account_id` in URL)

`POST /api/auth/switch-account` (body `{"membership_id": "<uuid>"}`) MUST be piped through `:auth` only (no `EnforceAccountScope` because there is no `:account_id` path param).
