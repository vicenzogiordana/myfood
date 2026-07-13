# Account Membership

## Purpose

Defines the `AccountMembership` join entity, its lifecycle, and the
canonical `Account.plan` taxonomy that drives the seat cap. This is the data
foundation every other Phase A spec builds on.

**Grill decisions referenced**: `context.md` §3 (Monetization plans), §4
(Account / User / AccountMembership, grill 2026-06-16 "Spotify Family"
multi-familia model).

## Requirements

### Requirement: AccountMembership schema

The system MUST persist an `account_memberships` row per `(account_id,
user_id)` with: `role` (`:owner | :member`, decision 5.2), `status`
(`:active | :invited | :suspended`), `invited_by_user_id` (nullable for the
founder-owner), `invite_token_hash` (nullable, single-use),
`invite_expires_at` (nullable), and `joined_at` (nullable while `:invited`).
A unique partial index on the active-state subset MUST guarantee at most
one membership per `(account_id, user_id)`.

#### Scenario: Insert a new :active membership

- GIVEN an `Account` of `:plan` `:family_4` and a `User` with no memberships
- WHEN the owner invites the User and the User accepts
- THEN exactly one row exists with `role: :member`, `status: :active`,
  `joined_at` set, `invite_token_hash: nil`

#### Scenario: Re-invite a previously suspended User

- GIVEN the User's existing membership has `status: :suspended`
- WHEN the owner issues a new invite
- THEN no second row is created; `invite_token_hash` and
  `invite_expires_at` are overwritten and `status` stays `:suspended`

### Requirement: Exactly one owner per Account

Every `Account` MUST have exactly one `:owner` membership with
`status: :active`. Owner removal or demotion is forbidden by the application
layer (see `invite-and-accept`).

#### Scenario: Attempt to demote the owner

- GIVEN `User_A` is the `:owner` of an Account
- WHEN any controller invokes a remove/leave for `User_A`
- THEN the membership MUST NOT be removed and the API MUST return
  `:cannot_remove_owner` (or `:cannot_leave_owned_account` for self-leave)

### Requirement: Seat cap per Account.plan

The system MUST enforce the seat cap atomically on invite and on
reactivation. Per `context.md` §3 the cap is "up to N" on
`:active + :invited` rows (decision 5.6 — `:trial` reserved, unused):

| Plan         | Max active members |
|--------------|--------------------|
| `:individual`| 1 (owner only)     |
| `:family_4`  | 4                  |
| `:family_6`  | 6                  |
| `:trial`     | 6 (reuses `:family_6`) |

#### Scenario: Fifth invite on a :family_4 Account

- GIVEN an Account with 4 `:active` memberships and `:plan :family_4`
- WHEN the owner calls `POST /api/accounts/:id/invites`
- THEN the system MUST return `409 seat_cap_reached` and MUST NOT mint a
  token, with the count taken under `SELECT … FOR UPDATE` on the Account
  row

### Requirement: Account.plan enum and subscription_plans seed

`Account.plan` MUST be an `Ecto.Enum` with values
`:individual | :family_4 | :family_6 | :trial`. The `:group` enum value
MUST NOT exist (decision 5.3). The `subscription_plans` table MUST seed rows
for all four `name`s with `account_id` NOT NULL enforced on the FK.

#### Scenario: Migrate Account from :group to a :plan enum value

- GIVEN a legacy `Account` with `account_type: :group`
- WHEN the migration runs
- THEN the row is rewritten so `account_type` is dropped and `plan` carries
  `:family_4`, and a `subscription_plans` row with `name: "family_4"` exists
  with `Account.subscription_plan_id` pointing at it

### Requirement: Backfill invariants from legacy User.account_id

The Phase A migration MUST backfill `account_memberships` so that:

1. Every legacy `(User, Account)` pair in `users.account_id` yields exactly
   one `AccountMembership` with `role` equal to the legacy `users.role`
   (`:owner` default), `status: :active`, `joined_at = users.inserted_at`.
2. Every Account has exactly one `:owner` membership.
3. `users.account_id` remains populated (NOT NULL dropped in a later
   migration; decision 5.1 dual-write window).

#### Scenario: Post-migration consistency check

- GIVEN a populated DB pre-Phase-A
- WHEN the backfill migration completes
- THEN `SELECT COUNT(*) FROM users u LEFT JOIN account_memberships m ON
  m.user_id = u.id AND m.account_id = u.account_id AND m.role = u.role
  WHERE m.id IS NULL` MUST return `0`, AND `SELECT account_id, COUNT(*)
  FROM account_memberships WHERE role = 'owner' GROUP BY account_id HAVING
  COUNT(*) <> 1` MUST return zero rows

## Cross-References

Decisions 5.1, 5.2, 5.3, 5.6; `context.md` §3 + §4. §4b deletion cascade
is deferred to a follow-up change.