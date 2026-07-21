# Archive Report: phase-a-tenancy-refactor

**Date**: 2026-07-21  
**Change**: `phase-a-tenancy-refactor`  
**Status**: ✅ **ARCHIVED AND CLOSED**  
**Archive Location**: `meal_planner_api/openspec/changes/archive/2026-07-21-phase-a-tenancy-refactor/`

---

## Executive Summary

The `phase-a-tenancy-refactor` change has been successfully implemented, fully verified, and archived. All 55 implementation tasks completed (confirmed via sdd-verify on 2026-07-20), with 512 passing tests and zero failures. The multi-tenant account membership model is now live on `main`, replacing the single-tenant `users.account_id` anchor with a join entity `AccountMembership` as the sole source of truth for tenancy. Three chained PRs (PR 1 data model + dual-write Guardian; PR 2 context + repo rewrites; PR 3 controllers + channels + cutover) landed without forced re-login, with the cutover flag (`MEAL_PLANNER_TENANCY_V2`) defaulting to `false` and flippable post-deploy for zero-downtime activation.

---

## Verification Summary

- **Tasks**: 55 / 55 complete (100%)
  - PR 1: 14 / 14 ✅
  - PR 2a: 11 / 11 ✅
  - PR 2b: 6 / 6 ✅
  - PR 3: 25 / 25 ✅
  - Post-PR-2b review fixes: 7 / 7 ✅

- **Test Coverage**: 
  - **512 tests passing** (0 failures)
  - Pre-Phase-A baseline: 285 tests
  - Post-Phase-A: 512 tests (+227 new)
  - Coverage spans all layers: migrations, schemas, services, contexts, controllers, channels, plugs

- **Code Quality**:
  - Strict TDD (RED → GREEN → REFACTOR) on every task
  - Zero regressions
  - All migrations have non-destructive `down/0` functions
  - Backfill invariants enforced in-transaction

---

## Artifacts Archived

All original change artifacts moved from `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/` to the archive directory (see Move Plan below):

- ✅ `proposal.md` — Reconstructed on 2026-07-21 (original was lost); documents the multi-tenant vision, scope, and approach
- ✅ `design.md` — Reconstructed on 2026-07-20; comprehensive design with 11 sections covering data model, Guardian, pipeline, tenancy scoping, invitations, channels, testing, rollout, and divergences from tasks
- ✅ `tasks.md` — 55 tasks across 3 PRs, all marked `[x]` complete; includes TDD evidence and per-task commit SHAs
- ✅ `apply-progress.md` — Multi-section document covering PR 1, PR 2a, PR 2b, and post-PR-2b review fixes with full commit history and risk analysis
- ✅ 6 delta specs (moved to main specs, see below)

---

## Main Specs Created (Merged from Delta Specs)

Three capability specs created under `meal_planner_api/openspec/specs/{domain}/spec.md`:

### 1. **Accounts** (`meal_planner_api/openspec/specs/accounts/spec.md`)
Merged from:
- `account-membership.md` — Data model, invariants, seat caps, atomic registration
- `invite-and-accept.md` — Invitation lifecycle, roster, remove/leave
- `multi-familia-switch-account.md` — Account switching for multi-familia users

**Coverage**: `account_memberships` table, `Account.plan` enum, backfill, seat cap enforcement, atomic registration, invitation lifecycle, membership roster, hard-delete, multi-familia switching.

### 2. **Auth** (`meal_planner_api/openspec/specs/auth/spec.md`)
Merged from:
- `auth-pipeline-and-current-resource.md` — Pipeline order, `VerifyTokenType`, `LoadCurrentMembership`, `EnforceAccountScope`
- `guardian-jwt-claims.md` — Dual-write JWT shapes (`access_v1`, `access_v2`), flag-gating, refresh semantics

**Coverage**: JWT claim shapes, Guardian dual-write, `:auth` pipeline, token type verification, account-scope enforcement, controller tenancy requirements.

### 3. **Channels** (`meal_planner_api/openspec/specs/channels/spec.md`)
Direct copy from:
- `membership-scoped-channels.md` — Socket connect, channel join guards, cross-Account checks, multi-familia isolation

**Coverage**: WebSocket tenancy, socket connect, four channels (Calendar, Planning, Cooking, AI), multi-familia socket connections, shopping/inventory HTTP-only isolation.

---

## Key Decisions Captured

**Guardian Strategy**: Dual-write token verification (both `access_v1` and `access_v2` verify at all times) enables zero-downtime cutover; minting is gated by `MEAL_PLANNER_TENANCY_V2` flag (fail-closed `false`).

**Tenancy Anchor**: `membership.account_id` replaces `user.account_id` as sole source of truth. `user.account_id` retained nullable for dual-write window; dropped from synthesized path post-PR-1 security fix.

**Seat Cap Model**: Resolved from `subscription_plans` by `Account.plan` name (`individual: 1, family_4: 4, family_6: 6, trial: 6`); `:active + :invited` count enforced under row-level lock (`SELECT … FOR UPDATE`).

**Invite Token Model**: 32 random bytes → URL-safe base64 plaintext (~43 chars), SHA-256 lower-hex hash (64 chars), 7-day TTL, single-use via `status != :invited`.

**Membership Removal**: Hard delete (no soft-delete). Stale legacy tokens (4-week TTL, no server revocation) stop working immediately on remove.

**Channel Footprint**: Only 4 channels shipped (`CalendarChannel`, `PlanningChannel`, `CookingChannel`, `AIChannel`). `shopping` and `inventory` enforce tenancy at HTTP controller layer only.

---

## Divergences from Original Tasks (As-Built)

Per `design.md` §11, the following intentional divergences reflect production code:

1. **No synthesized legacy membership** — Security fix: legacy `access_v1` tokens resolve to a *real* `:active` row, not an in-memory synthesized struct.
2. **Env-var wiring landed separately** — `MEAL_PLANNER_TENANCY_V2` → `:tenancy_v2_only` binding added via separate `tenancy-v2-flag-wiring` change (post-PR-3).
3. **Invite token columns retained** — Hash and expiry NOT nulled on accept; replay detected via `status != :invited`.
4. **`leave/2` lookup order** — Checks `:not_a_member` before `:cannot_leave_owned_account`.
5. **Four channels only** — No `shopping_channel` or `inventory_channel` created; those domains use HTTP-only isolation.
6. **`VerifyTokenType` as standalone plug** — Not a second `VerifyHeader` step; dedicated plug allows accepting two `typ` values.
7. **Guardian reattachments** — Only `:subscription_tier` and `:account_id` reattached; `:account_type` removed (no legacy calc needed).

---

## Risks and Remediation

**Post-Phase-A Follow-Up Changes Required**:

1. **`tenancy-v2-hardening`** — Remove `access_v1` issuance once clients consume `current_membership` fully.
2. **`drop-users-role`** — `users.role` was kept for Phase A dual-write; drop it once `account_memberships.role` is sole source.
3. **`account-transfer-dissolve`** — Owner cannot currently leave or transfer ownership; needed for household exit flows.
4. **Shopping/Inventory channels** (if needed) — Phase A left these as HTTP-only; could create dedicated channels in a follow-up.

**Known Limitations Accepted**:

- Membership is not soft-delete (no audit trail of removed members); acceptable for current scope.
- `:suspended` status exists but is never minted (reserved for re-invitation flow in future change).
- `users.role` is legacy compat (Phase A keeps it; removed later).

---

## Verification Artifacts and Links

- **Proposal**: `meal_planner_api/openspec/changes/archive/2026-07-21-phase-a-tenancy-refactor/proposal.md`
- **Design**: `meal_planner_api/openspec/changes/archive/2026-07-21-phase-a-tenancy-refactor/design.md`
- **Tasks**: `meal_planner_api/openspec/changes/archive/2026-07-21-phase-a-tenancy-refactor/tasks.md` (all 55 marked complete)
- **Apply Progress**: `meal_planner_api/openspec/changes/archive/2026-07-21-phase-a-tenancy-refactor/apply-progress.md` (per-task commit SHAs, TDD evidence)
- **Verify Report** (referenced): Full 55/55 confirmation on branch `docs/tenancy-tasks-reconcile` (committed to main 7b97ceb)

**Test Evidence**: 512 passing tests via `mix test` (final run post-PR-3 landing on main).

---

## SDD Cycle Complete

The change has passed all phases:
- ✅ **sdd-propose** — Proposal written (reconstructed)
- ✅ **sdd-spec** — 6 delta specs created, reviewed, merged into 3 main capability specs
- ✅ **sdd-design** — Design document written (reconstructed)
- ✅ **sdd-tasks** — 55 tasks defined, sequenced across 3 chained PRs
- ✅ **sdd-apply** — All 55 tasks implemented, TDD cycle evidence captured, code on main
- ✅ **sdd-verify** — 55/55 tasks verified complete, 512 tests passing, all blockers resolved
- ✅ **sdd-archive** — Change archived, specs merged into main, audit trail established

**Next change may proceed** — the tenancy foundation is now in place for downstream work (optimizer integration, AI behavior, tenant-scoped UI, etc.).
