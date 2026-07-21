# Account Membership Specification

> Reconstructed as-built on 2026-07-21 because the original was lost. Source: `design.md` §2 (Data model), the shipped `AccountMembership` schema, `AccountsMembership` context, and the 77 passing tenancy tests on branch `docs/tenancy-tasks-reconcile`.

## Purpose

Defines the `account_memberships` join entity — the sole source of truth for
"which User belongs to which Account, in what role, with what status" — and
the `Account.plan` seat-cap model it depends on. Replaces the historical
`users.account_id` single-tenancy anchor. See `design.md` §2, §10 Q2/Q3/Q10.

## Requirements

### Requirement: `account_memberships` table shape

The system MUST persist tenancy membership as rows in `account_memberships`
with `account_id`, `user_id`, `role` (`owner|member`), `status`
(`active|invited|suspended`), `invited_by_user_id`, `invite_token_hash`,
`invite_expires_at`, `joined_at`. `role` and `status` MUST be CHECK-constrained
at the DB level in addition to `Ecto.Enum` validation.

#### Scenario: Exactly one active membership per (account, user)

- GIVEN an `:active` membership already exists for `(account_id, user_id)`
- WHEN a second `:active` row is inserted for the same pair
- THEN the partial unique index `account_memberships_active_account_user_unique_index` raises `unique_violation`

#### Scenario: Invalid role or status rejected

- GIVEN a changeset with `role: :admin` or `status: :pending`
- WHEN `AccountMembership.changeset/2` validates it
- THEN the changeset is invalid (enum inclusion failure)

### Requirement: `Account.plan` replaces `account_type`

The system MUST resolve every Account to exactly one `plan` value
(`individual | family_4 | family_6 | trial`); the legacy `:group |
:individual` `account_type` enum MUST NOT exist post-migration.

#### Scenario: Legacy `:group` accounts become `family_4`

- GIVEN a pre-Phase-A account with `account_type: :group`
- WHEN migration `20260625000002_alter_accounts_to_plan_enum` runs
- THEN the account's `plan` is `:family_4` and the `account_type` column no longer exists

#### Scenario: Unknown plan rejected

- GIVEN `Account.changeset(%Account{}, %{plan: :unknown})`
- WHEN the changeset is validated
- THEN it is invalid (enum inclusion failure)

### Requirement: Backfill invariants enforced in-transaction

The system MUST backfill one `:active` membership per legacy
`(users.id, users.account_id)` pair and MUST refuse to complete the migration
if `check_account_membership_invariants()` finds any Account without exactly
one `:active :owner` membership.

#### Scenario: Invariant violation rolls back the migration

- GIVEN a seeded user with `account_id` set but no corresponding membership row
- WHEN `check_account_membership_invariants()` runs at the end of the backfill migration
- THEN it raises `backfill_invariant_failed` and the whole migration transaction rolls back

### Requirement: Seat cap resolved from `Account.plan`

`AccountsMembership.seat_usage/1` MUST count `:active + :invited` rows for an
Account and compare against the plan's capacity
(`individual: 1, family_4: 4, family_6: 6, trial: 6`).
`enforce_seat_cap/2` MUST return `{:error, :seat_cap_reached}` when
`active + invited + count_to_add` exceeds capacity.

#### Scenario: Seat cap reached on `family_4`

- GIVEN an Account on `:family_4` with 4 `:active` memberships
- WHEN `enforce_seat_cap(account, 1)` is called
- THEN it returns `{:error, :seat_cap_reached}`

#### Scenario: Capacity matches seeded `subscription_plans`

- GIVEN Accounts on each of `:individual`, `:family_4`, `:family_6`, `:trial`
- WHEN `seat_usage/1` is called for each
- THEN `capacity` is `1`, `4`, `6`, `6` respectively

### Requirement: Atomic registration creates the owner membership

`Accounts.register_with_password/1` MUST create the Account, the User, and
one `:owner :active` membership in a single `Ecto.Multi` transaction; any step
failing MUST roll back the entire registration (no orphan Account or User).

#### Scenario: Successful registration yields one owner membership

- GIVEN valid registration params
- WHEN `register_with_password/1` succeeds
- THEN exactly one `:owner :active` `AccountMembership` row exists for the new (user, account) pair

#### Scenario: Forced failure rolls back the Account

- GIVEN a duplicate email that will fail User insertion
- WHEN `register_with_password/1` is called
- THEN no Account row is persisted (the `Multi` transaction rolled back)

### Requirement: `users.role` retained for the dual-write window

`users.account_id` MUST be nullable and `users.role` MUST remain on the
`User` schema during Phase A (feeds legacy compatibility and the backfill
role default); it is not the tenancy source of truth once
`account_memberships.role` exists.

#### Scenario: Nullable `account_id` persists

- GIVEN a `User` changeset with `account_id: nil`
- WHEN the changeset is applied
- THEN it is valid and persists (no `NOT NULL` violation)
