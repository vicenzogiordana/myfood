# Proposal: Phase A — Tenancy Refactor (User → AccountMembership)

> **Owner sub-project**: `meal_planner_api`. Artifacts under
> `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/`.
> **Status**: `proposed`
> **PRD**: [vicenzogiordana/myfood#1](https://github.com/vicenzogiordana/myfood/issues/1) — Phase A.
> **Related context**: `context.md` §4 / §4b (Account, AccountMembership, deletion),
> `meal_planner_api/ARCHITECTURE.md` (Web / Application / Persistence layers).

## Intent

The current `meal_planner_api` has a single-User-per-Account model encoded as
`User.account_id`, with no `AccountMembership` table, no `:owner`/`:member`
roles, and an `:individual | :group` `account_type` that does not match the
PRD's plan taxonomy (`:individual | :family_4 | :family_6 | :trial`). This
refactor introduces the canonical multi-tenant model: every `User` can hold N
`AccountMembership`s, every `Account` has exactly one `:owner` membership, and
the JWT carries `membership_id` so a request is scoped to one Account without
requiring a URL prefix on every endpoint. Phase A delivers the data model, the
dual-write Guardian, the invite/accept/leave/switch flows, and the seat cap —
but defers pricing, RevenueCat binding, trial expiration, and Account
deletion/transfer to follow-up changes.

## Capabilities (contract with `sdd-spec`)

### New Capabilities

- `account-membership` — `AccountMembership` schema, lifecycle (`:active |
  :invited | :suspended`), role enforcement (`:owner` is unique per Account),
  seat cap per `Account.plan`.
- `invite-flow` — `POST /api/accounts/:account_id/invites`,
  `POST /api/invites/:token/accept`, `GET /api/accounts/:account_id/memberships`,
  `DELETE /api/accounts/:account_id/memberships/:user_id`.
- `account-switching` — `POST /api/auth/switch-account` re-issues a JWT
  carrying the new `membership_id` claim.
- `voluntary-leave` — `POST /api/accounts/:account_id/leave` for `:member`
  self-removal; owner returns `:cannot_leave_owned_account`.
- `tenancy-jwt` — Guardian token with `membership_id`, `account_id`, `role`,
  `plan` claims; `typ` claim `"access_v2"` distinguishes the new tokens
  during the dual-write window.

### Modified Capabilities

- `auth-session` — `current_user` + `current_membership` are both available
  on the `conn`/socket; existing endpoints keep accepting `account_id` from
  the URL but resolve it via the membership, not via `User.account_id`.
- `subscription-policy` — `Account.plan` becomes the policy source (replacing
  `account_type`); `MealPlannerApi.Subscriptions.policy_for_account/1`
  reads `plan` and resolves through `subscription_plans` by name.

## Scope

### In Scope

**Stream A — DB migration (PR 1)**
- `priv/repo/migrations/2026XXXX_create_account_memberships.exs` — new table
  with `(account_id, user_id)` unique partial index for one active membership
  per `(account, user)`, `role`, `status`, `invited_by_user_id`, `joined_at`,
  `invite_token`, `invite_expires_at`.
- `priv/repo/migrations/2026XXXX_add_account_memberships_backfill.exs` —
  backfill: for every existing `User`, insert one membership
  `(account_id, user_id, role: :owner, status: :active)`.
- `priv/repo/migrations/2026XXXX_alter_accounts_to_plan_enum.exs` — drop
  `account_type`, add `plan` (Ecto.Enum `:individual | :family_4 |
  :family_6 | :trial`); add `account_memberships.account_id NOT NULL` to
  `subscription_plans` seed; insert `:family_6` and `:trial` plan rows.
- `priv/repo/migrations/2026XXXX_make_user_account_id_nullable.exs` —
  relax `users.account_id` to nullable for the dual-write window only.

**Stream A — Schemas**
- New `lib/meal_planner_api/persistence/accounts/account_membership.ex`.
- Update `lib/meal_planner_api/persistence/accounts/account.ex` (replace
  `account_type` → `plan`, drop `has_many :users`).
- Update `lib/meal_planner_api/persistence/accounts/user.ex` (nullable
  `account_id`, add `has_many :memberships`).

**Stream B — App refactor (PR 2 + PR 3)**
- New context `lib/meal_planner_api/accounts_membership.ex` — public API:
  `invite/3`, `accept_invite/2`, `list_memberships/1`, `remove_member/2`,
  `leave/1`, `switch_account/2`, `current_membership/1`, `seat_usage/1`,
  `enforce_seat_cap/2`.
- New service `lib/meal_planner_api/services/invite_service.ex` — token
  mint/verify, expiry, single-use enforcement.
- Rewrite `lib/meal_planner_api/accounts.ex` to delegate tenancy to
  `AccountsMembership`; keep `register_user` flow that creates the first
  Account + owner membership atomically.
- New controller `lib/meal_planner_api_web/controllers/membership_controller.ex`
  (index, remove).
- New controller `lib/meal_planner_api_web/controllers/invite_controller.ex`
  (create by owner, accept by invitee).
- New controller `lib/meal_planner_api_web/controllers/account_lifecycle_controller.ex`
  (switch-account, leave).
- Update `lib/meal_planner_api_web/controllers/auth_controller.ex` to mint
  the new JWT (`typ: "access_v2"`) on register/login/refresh; keep
  `access_v1` mint path behind a feature flag for backwards compatibility.
- Update `lib/meal_planner_api_web/auth_pipeline.ex` to resolve
  `current_membership` from JWT claims and reject requests where
  `URL account_id ≠ JWT account_id`.
- Update `lib/meal_planner_api_web/channels/{planning,cooking,calendar,
  shopping,inventory,ai}_channel.ex` — read `account_id` from the
  membership claim, keep the existing `<channel>:<account_id>` topic shape
  (5.5 backwards-compat decision).
- Update `lib/meal_planner_api/data/*_repo.ex` and
  `lib/meal_planner_api/persistence/**` queries that filter by
  `user.account_id` → switch to `membership.account_id` for `:active`
  memberships.
- Update `lib/meal_planner_api/subscriptions.ex` to use `Account.plan`
  instead of `account_type`; `policy_for_account/1` resolves the
  `subscription_plans` row by `name` (5.3 decision).
- `test/support/factory.ex` and `factory_helpers.ex` — add factories for
  `AccountMembership` and multi-familia scenarios.
- New tests in `test/meal_planner_api/accounts_membership_test.exs` and
  `test/meal_planner_api_web/controllers/{membership,invite,
  account_lifecycle}_controller_test.exs` and channel tests asserting
  cross-Account isolation.

**Docs**
- Update `meal_planner_api/ARCHITECTURE.md` Auth Flow section with the
  dual-token (`access_v1` / `access_v2`) model.

### Out of Scope (deferred to follow-up changes)

| Item | Why deferred |
|---|---|
| Pricing tiers persistence / RevenueCat entitlement binding | Requires RevenueCat webhook → Account.plan mapping; Phase G (Polish) slice |
| Trial expiration timer (14-day `family_6` auto `:read_only` flip) | Needs scheduler + `:read_only` Account status; not safe in the same PR as the schema swap |
| Downgrade blocking logic (`:family_6` → `:family_4` with >4 active members) | Owner-driven flow, depends on billing surface; Phase G |
| Account deletion (A1 — 30-day tombstone, cascade) | Requires GDPR-shaped data export; full change of its own |
| Account transfer (change ownership without dissolve) | Per PRD §"Open questions" — TBD in design phase |
| Data export (GDPR Art. 20) | Per PRD §"User deletion (B1)" — TBD in design phase |

## Design Decisions (inherited from exploration, 2026-06-24)

| # | Decision | Choice | Why |
|---|---|---|---|
| 5.1 | `User.account_id` fate | Keep nullable for dual-write window; drop in a later migration after all read paths are migrated. | Zero-downtime, reversible, observable divergence. |
| 5.2 | Role granularity | `:owner` \| `:member` (binary). | PRD §"Open questions" — no admin/co-owner/viewer in MVP. |
| 5.3 | `Account.plan` enum | `:individual` \| `:family_4` \| `:family_6` \| `:trial`. | Maps to `subscription_plans.name`; `:group` enum is dropped (covered by `:family_4`/`:family_6`). |
| 5.4 | URL shapes | `POST /api/accounts/:account_id/invites`, `POST /api/invites/:token/accept`, `GET /api/accounts/:account_id/memberships`, `DELETE /api/accounts/:account_id/memberships/:user_id`, `POST /api/auth/switch-account`, `POST /api/accounts/:account_id/leave`. | RESTful, owner-only paths scoped by URL, `/auth/switch-account` is auth-only. |
| 5.5 | Channel topic shape | Keep `<channel>:<account_id>` for backwards compat. | Frontend already speaks the v1 topic; membership is verified server-side via the JWT `membership_id` claim. |
| 5.6 | `:trial` enum slot | Included, unused in Phase A. | Future-friendly — Phase G (trial expiration) reuses the slot without a schema change. |
| 5.7 | Owner-leave semantics | Owner **cannot** leave via `/leave`; returns `:cannot_leave_owned_account`. | Account transfer and deletion are deferred; the owner must explicitly dissolve or transfer first. |

## Approach — Three Chained PRs

Total forecast: ~1,500 lines changed. Strategy: **chained PRs, feature
branch chain** (per `chained-pr` skill, 400-line review budget). Each PR
ships independently and the deployment is gated by the JWT `typ` claim so
the new code is dark until flipped.

### PR 1 — DB migration + `AccountMembership` schema + dual-write Guardian

- **Scope** (~400 lines): all 4 migrations, the new schema file, factory
  additions, and a feature-flagged `MembershipsDualWrite` plug that mints
  `access_v2` alongside `access_v1`. No controller changes.
- **Dependencies**: none.
- **Verification**: `mix ecto.migrate` + `mix ecto.rollback` round-trip;
  `mix precommit`; new schema spec passes changeset validations.
- **Rollback**: revert migrations down to the pre-Phase-A snapshot. The
  `User.account_id` column is restored to `NOT NULL` after the down
  migration backfills from the destroyed memberships.
- **Risks**: long-running migration on a populated DB. Mitigation: each
  migration is `IF NOT EXISTS`-safe and the backfill runs in batches of
  1,000 with a 50ms sleep.

### PR 2 — Accounts context rewrite (no controller reach-through)

- **Scope** (~500 lines): new `AccountsMembership` context, `InviteService`,
  rewrite `MealPlannerApi.Accounts` to delegate tenancy, update
  `Subscriptions` to read `Account.plan`, update all `data/*_repo.ex`
  queries that filtered by `user.account_id` to filter by the active
  membership.
- **Dependencies**: PR 1 merged (the new schema and the `plan` column
  exist).
- **Verification**: `mix precommit`; new unit + integration tests for
  `AccountsMembership` and `InviteService`; existing tests still pass
  (controllers still read `current_user.account_id` and the pipeline
  derives `current_membership` from the JWT).
- **Rollback**: revert PR 2; PR 1 stays. The new tables and columns are
  unused; the legacy code path still works.
- **Risks**: large query rewrite can introduce N+1 regressions. Mitigation:
  property tests with `StreamData` covering multi-familia scenarios.

### PR 3 — Controllers + channels + services sweep + test fixtures + docs

- **Scope** (~600 lines): new controllers
  (`MembershipController`, `InviteController`,
  `AccountLifecycleController`), auth controller rewrite to mint
  `access_v2`, channel sweep to read account from membership, factory
  extensions for multi-familia, new tests across all entry points, and
  `ARCHITECTURE.md` updates.
- **Dependencies**: PR 2 merged.
- **Verification**: `mix precommit`; new controller tests + channel tests
  asserting cross-Account isolation; manual smoke test of invite/accept/
  switch/leave flows against a local DB.
- **Rollback**: revert PR 3; PR 1 + PR 2 stay. The new endpoints return
  404 (no route) and the legacy endpoints keep working.
- **Risks**: channel surface is broad. Mitigation: keep topic shape
  unchanged (5.5) so the frontend needs no client changes.

### Feature flag

JWT `typ` claim values:
- `"access_v1"` — legacy token, `current_user.account_id` resolves the
  tenancy. Issued until the deployment flips the env var
  `MEAL_PLANNER_TENANCY_V2=true`.
- `"access_v2"` — new token, `current_membership` is the source of
  truth. Issued when the env var is on. The auth pipeline accepts both
  during the cutover window.

The env-var flip is the **only** cutover step — no DB migration, no
forced logout, no mobile app release required for the initial rollout
(the React Native client keeps using the same `Authorization: Bearer
<jwt>` header). The mobile app gains access to the new endpoints
(`/api/accounts/.../invites`, `/api/auth/switch-account`, etc.) once its
own feature flags enable them.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `meal_planner_api/priv/repo/migrations/` | New (4 files) | Tenancy migration, backfill, plan-enum, account-id nullable |
| `meal_planner_api/lib/meal_planner_api/persistence/accounts/` | New + Modified | New `account_membership.ex`; `account.ex` and `user.ex` rewritten |
| `meal_planner_api/lib/meal_planner_api/accounts*.ex` | New + Modified | New `accounts_membership.ex`; `accounts.ex` delegates tenancy |
| `meal_planner_api/lib/meal_planner_api/services/` | New | `invite_service.ex` |
| `meal_planner_api/lib/meal_planner_api_web/controllers/` | New + Modified | 3 new controllers; `auth_controller.ex` rewrite |
| `meal_planner_api/lib/meal_planner_api_web/channels/` | Modified | All channels read `account_id` from membership claim |
| `meal_planner_api/lib/meal_planner_api_web/auth_pipeline.ex` | Modified | Resolves `current_membership`; rejects URL/JWT mismatch |
| `meal_planner_api/lib/meal_planner_api/data/` | Modified | Repo queries switch to `membership.account_id` |
| `meal_planner_api/lib/meal_planner_api/subscriptions.ex` | Modified | Reads `Account.plan` instead of `account_type` |
| `meal_planner_api/test/` | New + Modified | Factories, multi-familia scenarios, controller + channel tests |
| `meal_planner_api/ARCHITECTURE.md` | Modified | Auth Flow updated for dual-token model |

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Migration backfill is slow on a populated DB and locks writes | Medium | Batch backfill (1,000 rows, 50ms sleep); `CONCURRENTLY` index for the unique partial index; run in a maintenance window with `lock_timeout = 5s`. |
| Dual-write divergence (`user.account_id` vs active membership) silently corrupts reads | Medium | Feature flag gates `access_v2` issuance; integration tests assert both paths return the same `current_membership`; a one-shot reconciliation query in PR 2 surfaces drift. |
| Channel sweep breaks real-time for the existing frontend | Low | Keep `<channel>:<account_id>` topic shape (5.5); server-side `current_membership` enforcement is additive. |
| Frontend assumes the legacy JWT shape and crashes on `access_v2` | Low | Both token types pass the same `current_user` resolution; `access_v2` only **adds** `current_membership` — the React Native client is unaffected until it opts in. |
| Invite token leakage / replay | Low | Single-use tokens stored as a hash; `expires_at` enforced; `accept` invalidates the row. |
| Seat-cap race (two concurrent invites hit `members_count == 4`) | Medium | Enforce seat cap inside a `SELECT … FOR UPDATE` on the Account row in the invite transaction. |

## Rollback Plan

- **PR 1**: `mix ecto.rollback` to the pre-Phase-A snapshot (the four
  Phase A migrations down). The `User.account_id` column is restored to
  `NOT NULL` after a backfill-from-membership step in the down migration.
- **PR 2**: `git revert` the PR. The new tables/columns persist (no
  data loss) but no code path reads them; legacy reads keep working.
- **PR 3**: `git revert` the PR. The new routes return 404; legacy
  endpoints keep working. Set `MEAL_PLANNER_TENANCY_V2=false` to stop
  minting `access_v2` tokens; existing `access_v2` tokens expire on
  their normal TTL.
- **Catastrophic**: stop the API, drop the new tables (`account_memberships`,
  the new `accounts.plan` column), restore `accounts.account_type` from
  the migration snapshot. Total time: <30 minutes if the migration
  snapshot is current.

## Dependencies

- `meal_planner_api/openspec/config.yaml` — `strict_tdd: true`,
  `test_runner: "mix test"`, `max_changed_lines: 400` (chained PR
  strategy required — already planned).
- `meal_planner_api/ARCHITECTURE.md` — the Clean Architecture boundary
  the change respects (Web thin, Application owns use cases, Persistence
  owns queries).
- Project CONTEXT §4 / §4b — source of truth for the `Account`,
  `AccountMembership`, and `User` schema definitions.
- PRD issue #1 — Phase A section, "Phased approach" table.
- `meal_planner_api/openspec/artifacts/v2-planning-proposal.md` — prior
  change for stylistic reference.

## Success Criteria

- [ ] `User.account_id` is nullable; every existing `User` has a
      corresponding `AccountMembership` row with `role: :owner` and
      `status: :active`.
- [ ] `Account.plan` is an Ecto.Enum with values
      `:individual | :family_4 | :family_6 | :trial`; `:group` is gone
      from the schema.
- [ ] `subscription_plans` table has rows for all four plan names.
- [ ] `POST /api/accounts/:account_id/invites` mints a single-use token
      with `expires_at`; only the `:owner` can call it.
- [ ] `POST /api/invites/:token/accept` creates a `:member`
      `AccountMembership` and refuses re-use of the token.
- [ ] `GET /api/accounts/:account_id/memberships` returns the
      membership roster (owner + members) for any active member of the
      Account.
- [ ] `DELETE /api/accounts/:account_id/memberships/:user_id` removes
      a `:member`; refuses to remove the `:owner`; enforces seat cap on
      reactivation.
- [ ] `POST /api/auth/switch-account` re-issues a JWT with the new
      `membership_id` and `account_id` claims.
- [ ] `POST /api/accounts/:account_id/leave` removes a `:member`'s own
      membership; returns `:cannot_leave_owned_account` for the
      `:owner`.
- [ ] Auth pipeline rejects requests where the URL `:account_id` does
      not match the JWT `account_id` (for `access_v2` tokens).
- [ ] All 4 existing Phoenix Channels (`planning`, `cooking`, `calendar`,
      `shopping`, `inventory`, `ai`) accept the new `access_v2` token and
      keep their `<channel>:<account_id>` topic shape.
- [ ] Seat cap is enforced atomically: 5th invite on a `:family_4`
      Account returns `409 seat_cap_reached`.
- [ ] Cross-Account isolation: a test asserts that `User` of Account A
      cannot read/write Account B's resources via the API or any
      channel.
- [ ] `mix precommit` passes; new test coverage ≥ existing lines for
      touched modules.
- [ ] `meal_planner_api/ARCHITECTURE.md` reflects the dual-token
      (`access_v1` / `access_v2`) model and the membership claim.

## Open Questions Deferred to Design Phase

1. **Exact JWT claim shape** — what fields go in `access_v2` besides
   `membership_id`, `account_id`, `role`, `plan`? (E.g. `membership_status`,
   `seat_index`.) `sdd-design` to decide based on
   `meal_planner_api_web/auth_pipeline.ex` ergonomics.
2. **Dual-write TTL** — how long do we run `access_v1` issuance in
   parallel with `access_v2`? `sdd-design` to propose a date-based cutover
   (e.g. 30 days post-Phase A ship) and a forced refresh on next login.
3. **Test data factories for multi-familia** — how do factories express
   "User belongs to 2 Accounts with different roles"? `sdd-design` to
   propose a `with_membership(plan, role)` macro.
4. **Invite token entropy** — 32 bytes (UUID) or 64 bytes (`:crypto.
   strong_rand_bytes(48)` and base64-encoded)? `sdd-design` to size.
5. **`access_v1` deprecation policy** — when do we start refusing
   `access_v1` tokens entirely? Tied to the mobile app release cadence.
6. **Cross-vista consistency tests** — which existing cross-vista tests
   in `test/meal_planner_api/` need to switch from `user.account_id` to
   `membership.account_id`? `sdd-tasks` to enumerate.
7. **AccountMembership index naming** — `index_account_memberships_on_account_and_user`
   vs the project's existing convention. `sdd-design` to align with the
   existing migration history.

## References

- **PRD**: https://github.com/vicenzogiordana/myfood/issues/1
  (Phase A — "Tenancy refactor + trial").
- **Project CONTEXT** (ubiquitous language, grill decisions):
  `/Users/vicenzogiordana/Desktop/Progra/myfood/context.md` §4
  (Account / User / AccountMembership schema) and §4b
  (deletion semantics — informs what we do **not** ship in Phase A).
- **API architecture**:
  `/Users/vicenzogiordana/Desktop/Progra/myfood/meal_planner_api/ARCHITECTURE.md`
  (Web / Application / Persistence layers, Auth Flow section to be
  updated in PR 3).
- **API OpenSpec config**:
  `/Users/vicenzogiordana/Desktop/Progra/myfood/meal_planner_api/openspec/config.yaml`
  (`strict_tdd: true`, `max_changed_lines: 400` — drives the chained-PR
  strategy).
- **Project-root OpenSpec**:
  `/Users/vicenzogiordana/Desktop/Progra/myfood/openspec/config.yaml`
  (governs cross-sub-project concerns; Phase A is backend-only and
  stays in `meal_planner_api/openspec/`).
- **Prior proposal** (style reference):
  `/Users/vicenzogiordana/Desktop/Progra/myfood/meal_planner_api/openspec/artifacts/v2-planning-proposal.md`.

### Inline exploration report (no separate artifact on disk)

The orchestrator's `sdd-explore` report was delivered in-line in the
launch prompt. Key conclusions consumed by this proposal:

```
1. Current state: User.account_id is a single-tenant FK; no membership
   table; Account.account_type is :individual | :group (mismatches the
   PRD's :individual | :family_4 | :family_6 | :taxonomy); JWT has no
   membership_id claim.
2. Target state: AccountMembership is the join entity. A User holds N
   memberships. The JWT carries membership_id and account_id. Channels
   keep <channel>:<account_id> topics for backwards compat.
3. Top risks (covered in §Risks): migration backfill cost; dual-write
   divergence; channel sweep regression; frontend assumption of legacy
   JWT shape; invite-token replay; seat-cap race.
4. Classification into two streams: A (DB migration + schema) and
   B (app refactor). Stream A lands in PR 1; Stream B is split between
   PR 2 (context, no controllers) and PR 3 (controllers + channels).
5. Recommended PR strategy: three chained PRs, ~400/~500/~600 lines,
   each independently shippable and reversible, with the JWT typ
   claim as the cutover switch.
6. Open questions 5.1–5.7 are resolved in §Design Decisions above
   (orchestrator preflight, no user re-interview needed).
```
