# SDD Proposal: phase-a-tenancy-refactor

> **RECONSTRUCTION NOTE.** The original `proposal.md` for this change was lost.
> This document was reverse-engineered on 2026-07-21 from the as-built
> implementation, the reconstructed [`design.md`](design.md), the
> [`tasks.md`](tasks.md) PR strategy, and [`apply-progress.md`](apply-progress.md).
> Where the shipped code diverges from the original task descriptions, the code
> is the source of truth (see `design.md` §11).

## Change Summary

Convert the backend from a **single-tenant-per-user** model — where
`users.account_id` is the tenancy anchor and `accounts.account_type` is
`:individual | :group` — to a **membership-based multi-tenancy** model where a
join entity, `AccountMembership`, is the sole source of truth for which User
belongs to which Account, in what role, with what status. A single User can hold
one membership per Account ("multi-familia") and switch the active Account
without re-authenticating.

---

## Intent

Support real households: several people sharing one Account's plan, seats, and
data, and one person belonging to several Accounts. The current 1:1
`user → account` binding cannot express any of this — it has no concept of
roles, invitations, seat limits, or membership status, and it scopes every
query by `user.account_id`, which silently leaks or blocks data the moment a
user is associated with more than one Account.

The migration must be **zero-downtime and cause no forced re-login**: existing
clients holding legacy tokens keep working while the new model rolls out, and
the cutover to membership-scoped tokens is a single reversible flag flip — no
DB migration, no coordinated client release.

---

## Scope

### In Scope

1. **Membership data model**: `account_memberships` join table (role, status,
   invite fields), migrated and backfilled from every existing
   `(user, account)` pair without data loss, guarded by a DB-level invariant.
2. **Plan taxonomy**: replace `accounts.account_type` (`:individual | :group`)
   with `accounts.plan` (`:individual | :family_4 | :family_6 | :trial`)
   resolved through the `subscription_plans` table for seat caps and
   planning-day limits.
3. **Dual-write Guardian**: mint and verify both the legacy `access`
   (`access_v1`) token and the membership-scoped `access_v2` token
   simultaneously; issuance is gated by the `MEAL_PLANNER_TENANCY_V2` flag,
   verification always accepts both.
4. **Tenancy use cases**: invite (owner invites email), accept, roster/list,
   remove member, leave, switch-account, and seat-cap enforcement — behind clean
   HTTP controllers (`MembershipController`, `InviteController`,
   `AccountLifecycleController`) and an `EnforceAccountScope` plug.
5. **Membership-scoped realtime**: the four Phoenix channels
   (Calendar, Planning, Cooking, AI) authorize `join/3` against
   `membership.account_id` + `status == :active`.
6. **Repo scoping**: persistence queries scope by the resolved
   `membership.account_id` rather than `user.account_id`.
7. **Flag cutover wiring**: `config/runtime.exs` binds `MEAL_PLANNER_TENANCY_V2`
   to `:tenancy_v2_only` (fail-closed), making the documented cutover
   executable. *(Landed via the follow-on `tenancy-v2-flag-wiring` change.)*

### Out of Scope

- **Removing `access_v1` issuance** — deferred to a later `tenancy-v2-hardening`
  change, once clients fully consume `current_membership`. Phase A only makes
  `access_v2` mintable behind the flag.
- **`shopping` / `inventory` channels** — those domains enforce isolation in
  their HTTP controllers; no dedicated channels were created.
- The broader **application-layer architecture redo** (optimizer ports, AI
  behaviour injection) — a separate change.
- Mobile app and frontend integration work beyond the documented token contract.

---

## Problem Statement

| Issue | Location | Impact |
|---|---|---|
| Tenancy anchored on `users.account_id` (1:1) | every repo query | A user cannot belong to >1 Account; cross-Account access is unrepresentable |
| No roles / status / invitations | `accounts` + `users` only | Owner vs member, pending vs active, and invite flows have nowhere to live |
| `account_type :individual \| :group` | `accounts.account_type` | No seat caps or plan-driven limits; cannot model family tiers |
| Scoping by `user.account_id` in channels + repos | 4 channels, `*_repo.ex` | A multi-Account user would see the wrong Account's data |
| Token carries no membership context | Guardian `access` claims | The API cannot know which Account a request acts on without a DB round-trip per call |
| Cutover would force re-login | token shape change | Changing the token in place invalidates every live session at once |

### Root Cause

The original schema modeled "a user has an account" as a foreign key rather than
as a first-class relationship. Everything downstream — auth claims, query
scoping, channel authorization — inherited that assumption, so multi-tenancy
cannot be added without touching the data model, the token, and every scoping
boundary at once.

---

## Approach

Deliver as **three chained PRs** (feature-branch chain), each independently
reviewable under the 400-line budget, with the tenancy flag defaulting `false`
throughout so no behavior changes until an explicit post-deploy cutover. Full
detail in [`design.md`](design.md); summary:

1. **PR 1 — data model + dual-write Guardian.** Migrations for
   `account_memberships`, the `plan` enum, nullable `users.account_id`, and the
   backfill + invariant; the `AccountMembership` schema; and a Guardian that can
   mint `access_v2` (gated) while still issuing and verifying `access_v1`. No
   controller reach-through. Deploys with `MEAL_PLANNER_TENANCY_V2=false`.
2. **PR 2 — application layer.** The `AccountsMembership` context (claims,
   invite/accept, roster, remove, leave, switch-account, seat-cap),
   `InviteService`, atomic registration, `Subscriptions.policy_for_account/1`
   on `Account.plan`, and repo scoping by membership. Still flag-off.
3. **PR 3 — surfaces + cutover.** Controllers, router + `EnforceAccountScope`,
   the four-channel sweep, and the docs. Deploys flag-off, then the operator
   **flips `MEAL_PLANNER_TENANCY_V2=true` as a separate step** — a pure config
   change, no migration, no release, and reversible by flipping back.

**Key safety properties.** Verification always accepts both token types, so the
cutover never invalidates live sessions; the flag is fail-closed, so a mistyped
value stays on `access_v1`; and every migration `down/0` is non-destructive, so
a schema rollback is a snapshot restore rather than a data-mangling reversal.

### Migration safety

The backfill inserts one `:active` membership per existing
`(user, account)` pair and a DB-level invariant
(`check_account_membership_invariants()`) plus a partial unique index guarantee
exactly one active membership per `(account, user)`. `users.account_id` is made
nullable but retained as a compatibility read-path during the dual-write window.
