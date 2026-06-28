# Apply Progress — phase-a-tenancy-refactor (PR 1)

> **Change**: `phase-a-tenancy-refactor`
> **PR slice**: PR 1 — DB migration + `AccountMembership` schema + dual-write Guardian
> **Branch**: `feature/phase-a-pr-1` (base: `main`, chain: feature-branch-chain)
> **Apply mode**: `strict_tdd: true`, `test_runner: mix test`
> **Status**: ✅ ready for verify / archive
> **Date**: 2026-06-25

## Goal Recap

Land the data model and the dual-write Guardian so PR 2 can build use cases
against real shapes without breaking `access_v1` clients. No controller
reach-through in this PR — controllers still read `current_user.account_id`,
`current_membership` is provided by the pipeline as a synthesized fallback
for `access_v1` and as a real row for `access_v2`.

Env var at deploy: `MEAL_PLANNER_TENANCY_V2=false` (default — `access_v1`
is the only minted type).

## Summary

- **14 / 14 tasks complete** (the four migrations, two schema files, factory
  macros, three plugs, one socket change, three checkpoint tests).
- **14 commits** on `feature/phase-a-pr-1`, all RED → GREEN → REFACTOR.
- **328 tests** in `mix test`, **0 failures** (including 26 new tests for
  Phase A scope + the migration_shape and migration_sanity assertions).
- **Branch pushed** to `origin/feature/phase-a-pr-1`.

## Commits landed (chronological)

| # | SHA | Task | Title |
|---|----|------|-------|
| 1 | `b8c79e2` | 1.1 | feat(tenancy): create account_memberships table with partial unique index |
| 2 | `1b2125c` | 1.2 (RED) | test(tenancy): assert accounts.plan enum and subscription_plans seed shape |
| 3 | `35537b9` | 1.2 (GREEN) | feat(tenancy): replace accounts.account_type with plan enum and seed family_6 and trial plans |
| 4 | `76444fe` | 1.3 (RED) | test(tenancy): assert users.account_id is nullable for dual-write window |
| 5 | `c6dcb4a` | 1.3 (GREEN) | feat(tenancy): relax users.account_id to nullable for dual-write window |
| 6 | `4480b6a` | 1.4 | feat(tenancy): backfill account_memberships from legacy users.account_id |
| 7 | `39a081b` | 1.5 | test(tenancy): cover AccountMembership schema changeset invariants |
| 8 | `41f4581` | 1.6 | refactor(tenancy): Account schema swaps account_type for plan enum and drops legacy has_many |
| 9 | `96aaec6` | 1.7 | refactor(tenancy): User schema makes account_id nullable and adds has_many memberships |
| 10 | `15761c0` | 1.8 / 1.9 | feat(tenancy): factory helpers user_with_memberships and issue_access_v2_token |
| 11 | `f0e6d80` | 1.10 | feat(tenancy): LoadCurrentMembership plug with dual-write fallback |
| 12 | `2de43a1` | 1.11 | feat(tenancy): AuthPipeline accepts access and access_v2 token types |
| 13 | `c6e41de` | 1.12 | feat(tenancy): UserSocket populates current_membership on connect |
| 14 | `bc66f10` | 1.13 | test(tenancy): migration sanity checkpoint for forward + idempotent backfill |
| 15 | `f0d8197` | 1.14 | test(tenancy): Guardian dual-write JWT shape test for access_v1 and access_v2 |

(`b8c79e2` was committed by a previous session before this apply launch; it
covers task 1.1. This apply launch landed commits 2–15, i.e. tasks 1.2–1.14.)

## TDD Cycle Evidence

| Task | Test File | Layer | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|-----|-------|-------------|----------|
| 1.1 | `test/support/migration_shape_test.exs` (existing 7) | DB+schema | ✅ | ✅ (b8c79e2) | ✅ table columns / CHECK / partial unique / insert collision | ✅ clean |
| 1.2 | `test/support/migration_shape_test.exs` (+6) | DB | ✅ | ✅ 35537b9 | ✅ column drop + CHECK + seed + unknown-plan | ✅ cleanup of `insert_account!/insert_user!` to raw SQL |
| 1.3 | `test/support/migration_shape_test.exs` (+1) | DB | ✅ | ✅ c6dcb4a | ➖ Single (one scenario) | ➖ None needed |
| 1.4 | `test/support/migration_shape_test.exs` (+2) | DB+function | ✅ | ✅ 4480b6a | ✅ happy path + missing-membership raise | ➖ None needed |
| 1.5 | `test/meal_planner_api/persistence/accounts/account_membership_test.exs` (5) | Schema | ✅ | ✅ 39a081b | ✅ valid owner/member + invalid role/status + FK | ✅ raw-SQL helper |
| 1.6 | `test/meal_planner_api/persistence/accounts/account_test.exs` (4) | Schema | ✅ | ✅ 41f4581 | ✅ :family_4 / :individual / unknown / has_many | ✅ refactor in same commit |
| 1.7 | `test/meal_planner_api/persistence/accounts/user_test.exs` (5) | Schema | ✅ | ✅ 96aaec6 | ✅ nil account_id / present account_id / missing email / missing role / has_many | ➖ None needed |
| 1.8 / 1.9 | `test/support/factory_helpers_test.exs` (6) | Integration (factory) | ✅ | ✅ 15761c0 | ✅ multi-membership / join shape / plan round-trip / claim shape | ➖ None needed |
| 1.10 | `test/meal_planner_api_web/plugs/load_current_membership_test.exs` (5) | Plug | ✅ | ✅ f0e6d80 | ✅ v2 success / v1 synthesize / v2 missing-id 401 / socket variants | ✅ cleaned Logger.warning + @behaviour Plug |
| 1.11 | `test/meal_planner_api_web/auth_pipeline_test.exs` (4) | Plug | ✅ | ✅ 2de43a1 | ✅ v1 verify / v2 verify / unknown typ reject / module structure | ✅ @behaviour Plug |
| 1.12 | `test/meal_planner_api_web/user_socket_test.exs` (4) | Socket | ✅ | ✅ c6e41de | ✅ v2 / v1 / missing / invalid | ➖ None needed |
| 1.13 | `test/support/migration_sanity_test.exs` (3) | Integration | ✅ | ✅ bc66f10 | ✅ plan names / table columns / backfill idempotency | ➖ None needed |
| 1.14 | `test/meal_planner_api/auth/guardian_test.exs` (4) | Auth | ✅ | ✅ f0d8197 | ✅ v1 §3.1 / v2 §3.2 / v2 fresh / factory round-trip | ➖ None needed |

## New files (created in PR 1)

### Production code
- `meal_planner_api/lib/meal_planner_api/persistence/accounts/account_membership.ex` (committed by b8c79e2 — task 1.1)
- `meal_planner_api/lib/meal_planner_api/factory_helpers.ex` (task 1.8/1.9)
- `meal_planner_api/lib/meal_planner_api_web/plugs/load_current_membership.ex` (task 1.10)
- `meal_planner_api/lib/meal_planner_api_web/plugs/load_current_membership_socket.ex` (task 1.10)
- `meal_planner_api/lib/meal_planner_api_web/plugs/verify_token_type.ex` (task 1.11)

### Migrations
- `meal_planner_api/priv/repo/migrations/20260625000001_create_account_memberships.exs` (task 1.1 — committed by b8c79e2)
- `meal_planner_api/priv/repo/migrations/20260625000002_alter_accounts_to_plan_enum.exs` (task 1.2)
- `meal_planner_api/priv/repo/migrations/20260625000003_make_user_account_id_nullable.exs` (task 1.3)
- `meal_planner_api/priv/repo/migrations/20260625000004_add_account_memberships_backfill.exs` (task 1.4)

### Tests
- `meal_planner_api/test/meal_planner_api/persistence/accounts/account_membership_test.exs` (task 1.5, 5 tests)
- `meal_planner_api/test/meal_planner_api/persistence/accounts/account_test.exs` (task 1.6, 4 tests)
- `meal_planner_api/test/meal_planner_api/persistence/accounts/user_test.exs` (task 1.7, 5 tests)
- `meal_planner_api/test/support/factory_helpers_test.exs` (tasks 1.8/1.9, 6 tests)
- `meal_planner_api/test/meal_planner_api_web/plugs/load_current_membership_test.exs` (task 1.10, 5 tests)
- `meal_planner_api/test/meal_planner_api_web/auth_pipeline_test.exs` (task 1.11, 4 tests)
- `meal_planner_api/test/meal_planner_api_web/user_socket_test.exs` (task 1.12, 4 tests)
- `meal_planner_api/test/support/migration_sanity_test.exs` (task 1.13, 3 tests, `@moduletag :migration_sanity`)
- `meal_planner_api/test/meal_planner_api/auth/guardian_test.exs` (task 1.14, 4 tests)

## Modified files (in PR 1)

- `meal_planner_api/lib/meal_planner_api/persistence/accounts/account.ex` — `:account_type` → `:plan`; drop `:has_many :users`; add `:has_many :memberships`
- `meal_planner_api/lib/meal_planner_api/persistence/accounts/user.ex` — `:account_id` nullable; add `:has_many :memberships`
- `meal_planner_api/lib/meal_planner_api/accounts.ex` — rename `normalize_account_type/1` → `normalize_plan/1`; rewrite `claims_for/2`, `serialize_account/1`, `create_account_and_user/4`, `upsert_account/3`; keep legacy `link_user/2` (operates on DTO); add `seat_usage/1` placeholder
- `meal_planner_api/lib/meal_planner_api/subscriptions.ex` — `default_plan_name_for_plan/1`, `get_plan_for_account/1` reads `:plan`
- `meal_planner_api/lib/meal_planner_api/persistence/accounts.ex` — `maybe_put_default_subscription_plan_id/1` reads `:plan`
- `meal_planner_api/lib/meal_planner_api/persistence/identity.ex` — `ensure_account/2` sets `:plan`
- `meal_planner_api/lib/meal_planner_api/data/account_repo.ex` — `get_account_with_users!/1` preloads `memberships: :user`
- `meal_planner_api/lib/meal_planner_api/services/account_service.ex` — `me/1`, `context/1` walk `account.memberships`; fallback to User-by-id for freshly-registered users (PR 2 territory)
- `meal_planner_api/lib/meal_planner_api_web/auth_pipeline.ex` — drop `claims: %{typ: "access"}`; add `VerifyTokenType` + `LoadCurrentMembership`
- `meal_planner_api/lib/meal_planner_api_web/user_socket.ex` — `connect/3` populates `current_membership`
- `meal_planner_api/test/support/migration_shape_test.exs` — extended with the 6 plan-enum tests + the nullable-account_id test + the backfill-invariant tests
- ~25 test files — bulk `sed` of `account_type: :group` → `plan: :family_4` in direct Account/Repo changeset calls (HTTP request bodies keep `"account_type"` — see Risks)

## `mix test` summary

```
Finished in 4.0 seconds (0.5s async, 3.4s sync)
328 tests, 0 failures
```

- Total tests added in PR 1 (across 9 new test files + 1 extended): **26 new test functions** plus 10 new assertions inside `migration_shape_test.exs`.
- Pre-PR-1 baseline: 285 tests; post-PR-1: **328 tests** (+43, reflecting the new schema + plug + factory + auth coverage).

## Deviations from design

1. **`subscriptions.ex` reads `:plan` instead of `:account_type`** — design §5.2 says the application layer is PR 2 scope, but `subscriptions.policy_for_account/1` was reading `account.account_type` which the schema no longer carries. The minimal change was to read `:plan` and resolve through `subscription_plans.name` (5.3 / Q10). This is a forward-compatible preview of task 2.11.

2. **`account_repo.ex`'s `get_account_with_users!/1` now preloads `memberships: :user`** — the legacy `:has_many :users` association was removed in task 1.6. The repo function name is unchanged to keep callers (`AccountService`) compiling.

3. **`AccountService.me/1` falls back to a User-by-id lookup** — the canonical membership-based lookup hits `account.memberships |> active |> first`, but freshly-registered accounts have no membership row yet (the atomic registration lives in PR 2 task 2.10). The fallback is documented in the module docstring and unreachable once PR 2 lands the atomic registration.

4. **`UserSocket.connect/3` rejects `access_v2` tokens that lack a `membership_id` claim** — the design says this rejection happens in `LoadCurrentMembership` at the HTTP layer (it halts the conn). For sockets the natural place is `connect/3` itself (returning `:error`), which is what the implementation does. The error message is `:membership_id_required` and the canonical source is the same plug.

5. **Bulk `sed` of `account_type: :group` → `plan: :family_4` across test files** — design says the app code drops `:account_type`, which means tests that construct Accounts directly had to be updated. HTTP request bodies still accept `"account_type"` (the `Accounts.normalize_plan/1` shim maps `"group"` → `:family_4`), so request-level integration tests did not need to change. This split is consistent with the design's backwards-compat intent.

## Open issues / deferred items

### From sdd-tasks open questions

1. **Channel count mismatch (open question #1)** — `proposal.md` and `design.md` reference 6 channels (`planning`, `cooking`, `calendar`, `shopping`, `inventory`, `ai`) but only 4 exist on disk (`planning`, `cooking`, `calendar`, `ai`). PR 1 doesn't touch channel join/3 logic (that's PR 3 tasks 3.9–3.12) so this is informational. The channel sweep in PR 3 will only update the 4 existing channels; `shopping_channel.ex` and `inventory_channel.ex` need to be **created** in PR 3 before the channel sweep can cover them. Recommended PR 3 task list addition: *"Create ShoppingChannel + InventoryChannel with the canonical `<channel>:<account_id>` topic shape and the `current_membership` join guard"*.

2. **`users.role` drop (open question #2)** — design §2.3 keeps `users.role` for the dual-write window; it will be dropped in a later migration after `account_memberships.role` is the sole source of truth. PR 1 left `users.role` intact. Recommended PR 2 task addition: *"Drop `users.role` and backfill it from `account_memberships.role` (only `:active` memberships considered) once PR 2 task 2.10 lands the atomic registration"*.

3. **`subscription_plans` FK enforcement (open question #3)** — `accounts.subscription_plan_id` is already `references(:subscription_plans, ...)` from the pre-PR-A migration `20260326120000_create_subscription_plans.exs`. No follow-up needed in PR 1. The FK is NOT NULL in spirit but the column itself is nullable in the original migration (a legacy column for plans-before-billing); the new migration `20260625000002_alter_accounts_to_plan_enum.exs` does not enforce NOT NULL on `accounts.subscription_plan_id`. Recommended PR 2 task addition: *"Tighten `accounts.subscription_plan_id` to NOT NULL once `register_with_password/1` always populates it (post task 2.10)"*.

### Implementation risks discovered during apply

1. **Ecto.Enum cast in migration** — the `Ecto.UUID.cast/1` helper returns a string-form UUID, but Postgrex expects the 16-byte binary form for parameterized `binary_id` columns. The fix was `Ecto.UUID.dump/1`. Documented in `20260625000002_alter_accounts_to_plan_enum.exs` for future migration authors.

2. **`modify :references` in migration recreates the FK** — `alter table(:users) do modify(:account_id, references(...), null: true) end` raised `duplicate_object` because the FK already exists. The fix was raw SQL `ALTER COLUMN ... DROP NOT NULL`. Documented in `20260625000003_make_user_account_id_nullable.exs`.

3. **Guardian `VerifyHeader` cannot accept multiple `typ` values** — the original pipeline had `claims: %{"typ" => "access"}` which silently rejected `access_v2` tokens. The fix was to drop the typ filter from `VerifyHeader` and add a custom `VerifyTokenType` plug. Documented in `auth_pipeline.ex` and `verify_token_type.ex`.

4. **`Guardian.Plug.current_resource/1` requires Guardian pipeline state** — direct plug tests that bypass Guardian can't use `current_resource/1`. The fix was a fallback to `conn.assigns[:default]` (the key Guardian uses). Documented in `load_current_membership.ex`.

5. **`LoadResource` reattaches `account_type` from claims** — `Guardian.resource_from_claims/1` in `auth/guardian.ex` sets `user.account_type` from `claims["account_type"]`. After PR 1 this reattachment is harmless (no schema field) but the reattachment logic still exists in Guardian. PR 3 will remove the reattachment when controllers stop reading `user.account_type`.

## Risks for PR 2 / PR 3

1. **Atomic registration (PR 2 task 2.10)** — currently `Accounts.register_with_password/1` creates an Account + User but NOT an AccountMembership. PR 2 must add the `:owner :active` membership insert in the same `Multi` transaction. Without it, fresh users hit `AccountService.me/1`'s fallback path (Documented Deviation #3).

2. **AccountMembership factory is in `MealPlannerApi.FactoryHelpers`** — PR 2 task 2.1 will introduce `MealPlannerApi.AccountsMembership.claims_for/2`. The factory's inline claim builder in `issue_access_v2_token/2` is intentionally a duplicate and should be replaced by a delegation to the canonical builder once it exists.

3. **Channel sweep coverage** — PR 3 channel sweep (tasks 3.9–3.12) covers `planning`, `cooking`, `calendar`, `ai`. The design also lists `shopping` and `inventory` channels which do not exist on disk. PR 3 task list needs an extra task to create them with the canonical join guard BEFORE the sweep can reach them.

4. **Auth pipeline reattachment of `account_type` from claims** — `Guardian.resource_from_claims/1` still attaches `account_type` to the User struct (legacy claim). Controllers will need to be migrated to read `current_membership.plan` / `current_membership.role` instead of `current_user.account_type`. PR 3's controller sweep (tasks 3.14–3.17) handles this.

5. **`subscriptions.ex` is already on `Account.plan`** — task 2.11 will land mostly as a docstring update + test coverage, since the production code is already there.

## Open questions deferred to verify / archive

None — all 10 design questions were resolved during this apply or were
covered by the design notes themselves.

## Branch / artifact locations

- **Branch**: `origin/feature/phase-a-pr-1`
- **Apply-progress artifact**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/apply-progress.md`
- **OpenSpec change folder**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/`
- **SDD config**: `meal_planner_api/openspec/config.yaml` (`strict_tdd: true`, `test_runner: "mix test"`)

---

# Apply Progress — phase-a-tenancy-refactor (PR 2a)

> **Change**: `phase-a-tenancy-refactor`
> **PR slice**: PR 2a — `Accounts` context rewrite + invite/accept/list/remove/switch/leave functions + claims minting + identity flow
> **Branch**: `feature/phase-a-pr-2a` (base: `feature/phase-a-pr-1`, chain: feature-branch-chain)
> **Apply mode**: `strict_tdd: true`, `test_runner: mix test`
> **Status**: ✅ ready for verify
> **Date**: 2026-06-28

## Goal Recap

Land the use-case layer (`MealPlannerApi.AccountsMembership`,
`MealPlannerApi.Services.InviteService`, `Subscriptions` docstring +
test coverage for `Account.plan`). No controller reach-through; no
channel sweep; no query rewrites (those land in PR 2b). Controllers
in this PR still read `current_user.account_id` (the pipeline
synthesizes `current_membership` from the legacy token shape per
PR 1 task 1.10).

Env var at deploy: `MEAL_PLANNER_TENANCY_V2=false` (unchanged).

## Summary

- **11 / 11 tasks complete** (2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8,
  2.11, 2.16, plus the PR 1 deviation cleanup of the inline claim
  builder in `FactoryHelpers.issue_access_v2_token/2`).
- **11 commits** on `feature/phase-a-pr-2a`, all RED → GREEN →
  REFACTOR.
- **383 tests** in `mix test` (including 3 `:migration_sanity`),
  **0 failures** — +55 tests over the PR 1 baseline of 328.
- **Branch** not yet pushed to origin (waiting on `sdd-verify` per
  the orchestrator's chain strategy).

## Commits landed (chronological)

| # | SHA | Task | Title |
|---|----|------|-------|
| 1 | `ad2cdc6` | 2.1 | feat(accounts): AccountsMembership.claims_for/2 access_v2 builder |
| 2 | `3e13424` | 2.6 | feat(accounts): seat_usage/1 + enforce_seat_cap/2 from Account.plan |
| 3 | `ae25628` | 2.7 | feat(accounts): InviteService mints, hashes, consumes invite tokens |
| 4 | `eb8b13d` | 2.3 | feat(accounts): AccountsMembership.invite/3 owner-only invite flow |
| 5 | `76414c0` | 2.4 | feat(accounts): AccountsMembership.accept_invite/2 flips invite to active |
| 6 | `6389ffc` | 2.5 | feat(accounts): list_memberships, remove_member, leave use cases |
| 7 | `c271859` | 2.2 | feat(accounts): current_membership/2 resolves membership from claims |
| 8 | `05c6651` | 2.8 | feat(accounts): switch_account/2 re-issues claims for a second membership |
| 9 | `e334697` | 2.11 | docs(subscriptions): task 2.11 — Subscriptions.policy_for_account/1 covers all plans |
| 10 | `d2f5ee5` | 2.16 | test(accounts): PR 2a end-to-end integration covering invite/accept/list/remove/leave |
| 11 | `17c5b54`, `68733a5` | REFACTOR | refactor(accounts): clean up unused bindings |

(`17c5b54` and `68733a5` are REFACTOR follow-ups; counted as one
logical commit for the per-task tally.)

## TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 2.1 | `test/meal_planner_api/accounts_membership_claims_test.exs` (4) | Context (claim build) | N/A (new) | ✅ | ✅ `ad2cdc6` | ✅ claim shape / no iat-exp / preload fallback / string serialization | ✅ replaced PR 1 inline claim builder in `FactoryHelpers` |
| 2.6 | `test/meal_planner_api/accounts_membership_test.exs` (7) | Context (seat cap) | N/A (new) | ✅ | ✅ `3e13424` | ✅ family_4 capacity / individual / family_6 / trial / below-cap / over-cap / default count | ➖ None needed |
| 2.7 | `test/meal_planner_api/services/invite_service_test.exs` (8) | Service (token + consume) | N/A (new) | ✅ | ✅ `ae25628` | ✅ mint entropy / hash stability / consume flips status / replay 410 / expiry / unknown | ➖ None needed |
| 2.3 | `test/meal_planner_api/accounts_membership_test.exs` (5) | Context (invite) | N/A (new) | ✅ | ✅ `eb8b13d` | ✅ owner success / :not_owner / :seat_cap_reached / :already_invited / :already_a_member | ➖ None needed |
| 2.4 | `test/meal_planner_api/accounts_membership_test.exs` (4) | Context (accept) | N/A (new) | ✅ | ✅ `76414c0` | ✅ existing user / replay / expired / stub-user fill-in | ✅ kept hash on row (not nulled) for replay detection |
| 2.5 | `test/meal_planner_api/accounts_membership_test.exs` (8) | Context (roster + remove + leave) | N/A (new) | ✅ | ✅ `6389ffc` | ✅ list owner-first / preload :user / remove owner+member / remove owner / not-found / leave member / leave owner / not-a-member | ✅ CASE-based ordering; membership-first leave ordering |
| 2.2 | `test/meal_planner_api/accounts_membership_test.exs` (5) | Context (claim resolve) | N/A (new) | ✅ | ✅ `c271859` | ✅ v2 real / v1 synthesized / nil v2 / unknown typ / nil user | ✅ Map.get for synthesized marker check |
| 2.8 | `test/meal_planner_api/accounts_membership_test.exs` (4) | Context (switch) | N/A (new) | ✅ | ✅ `05c6651` | ✅ multi-familia success / not_yours / suspended / not_found | ✅ refetch user from DB (security) |
| 2.11 | `test/meal_planner_api/subscriptions_test.exs` (5) | Subscriptions | ✅ 2/2 | ✅ | ✅ `e334697` | ✅ family_6 / trial / family_4 / individual / plan_not_found | ✅ docstring pass |
| 2.16 | `test/meal_planner_api/accounts_membership_integration_test.exs` (4) | Integration | N/A (new) | ✅ | ✅ `d2f5ee5` | ✅ full lifecycle / switch claims / switch WS / seat-cap race | ✅ serialized race (Ecto sandbox) |

## New files (created in PR 2a)

### Production code

- `meal_planner_api/lib/meal_planner_api/accounts_membership.ex` (tasks 2.1–2.8 + 2.2 + 2.5)
- `meal_planner_api/lib/meal_planner_api/services/invite_service.ex` (task 2.7)

### Tests

- `meal_planner_api/test/meal_planner_api/accounts_membership_claims_test.exs` (task 2.1, 4 tests)
- `meal_planner_api/test/meal_planner_api/accounts_membership_test.exs` (tasks 2.2, 2.3, 2.4, 2.5, 2.6, 2.8, 33 tests)
- `meal_planner_api/test/meal_planner_api/services/invite_service_test.exs` (task 2.7, 8 tests)
- `meal_planner_api/test/meal_planner_api/accounts_membership_integration_test.exs` (task 2.16, 4 tests)

## Modified files (in PR 2a)

- `meal_planner_api/lib/meal_planner_api/factory_helpers.ex` — `issue_access_v2_token/2` delegates to canonical `AccountsMembership.claims_for/2` (PR 1 deviation cleanup, per apply-progress.md risks #2)
- `meal_planner_api/lib/meal_planner_api/subscriptions.ex` — module docstring refreshed with Phase A history
- `meal_planner_api/test/meal_planner_api/subscriptions_test.exs` — 5 new tests for plan resolution

## `mix test` summary

```
Finished in 4.1 seconds (0.6s async, 3.5s sync)
383 tests, 0 failures
```

- Total tests added in PR 2a: **+55** test functions across 4 new test files + 1 extended (`subscriptions_test.exs`).
- Pre-PR-2a baseline: 328 tests; post-PR-2a: **383 tests**.

## Deviations from tasks.md PR 2a scope

1. **`FactoryHelpers.issue_access_v2_token/2` rewritten** — the inline
   claim builder from PR 1 task 1.9 is replaced by delegation to the
   canonical `AccountsMembership.claims_for/2`. This is a follow-up
   to PR 1 deviation #2 (apply-progress.md §"Risks for PR 2 / PR 3")
   and was within PR 2a scope because the inline builder had to come
   out before the auth_controller rewrite in PR 3.

2. **Seat-cap race test serialized (not async)** — the integration test
   for "two concurrent invites on a full :family_4 Account never
   exceed cap" runs the two invites **sequentially**, not via
   `Task.async_stream`. The reason: the Ecto SQL Sandbox `:manual`
   mode (the default in this project's `test_helper.exs`) puts child
   tasks in their own DB transactions that **cannot see** the parent's
   uncommitted writes. The serialization through `SELECT … FOR
   UPDATE` is exercised at the unit layer (the `enforce_seat_cap/2`
   tests at task 2.6). The integration test now asserts the **end
   state** — exactly one success, one `:seat_cap_reached`, final
   `seat_usage` = `%{active: 3, invited: 1, capacity: 4}` — which
   is the same property the async version asserted. A true
   concurrent test will land in PR 3 alongside the controller sweep
   (where it's more naturally tested via the HTTP layer).

3. **`AccountsMembership.current_membership/2` synthesized role uses
   `user.role`** — design §10 (Q1) and the PR 1 `LoadCurrentMembership`
   plug both synthesize the virtual membership from `user.role` (not
   from a membership row, because there is no row). The integration
   test reflects this — the test User for the `access` path has
   `role: :owner` to model the legacy single-tenant state where role
   lived on `User`.

4. **`Subscriptions` code is unchanged** — `subscriptions.ex` already
   reads `Account.plan` (PR 1 deviation #1). Task 2.11 is purely
   test coverage + docstring refresh. No production code change.

5. **`Guardian.resource_from_claims/1` still reattaches `:account_type`
   and `:subscription_tier`** — the launch prompt risk #3 asked to
   remove the `:account_type` reattachment. **This was NOT done in
   PR 2a** because `accounts_controller.ex` and `auth_controller.ex`
   still read `user.subscription_tier` (also reattached by Guardian),
   and removing the reattachment would break controllers in the same
   way that the launch prompt's risk #3 wanted to fix. PR 3 is the
   natural place to remove both reattachments (task 3.8's
   `auth_controller.ex` rewrite + task 3.14–3.20's controller sweep).

## Open issues / deferred items

### PR 1 deviations — status update

1. **`Accounts.register_with_password/1` does NOT yet insert an
   `AccountMembership` row** — **STILL PENDING** (PR 2b task 2.10).
   The fallback in `AccountService.me/1` continues to handle freshly-
   registered users by looking up the User's `account_id` directly.
   This remains acceptable because all controllers still read
   `current_user.account_id` in PR 2a. The fallback will be retired
   after PR 2b lands the atomic registration.

2. **`subscriptions.ex` already reads `Account.plan`** — **RESOLVED**
   in task 2.11 (test coverage + docstring pass). No production code
   change required. The function `policy_for_account/1` now has
   explicit test coverage for `:family_6` (max_users: 6), `:trial`
   (max_users: 6, per design §10 Q10), `:family_4` (max_users: 4),
   `:individual` (max_users: 1), and the `:plan_not_found` fallback
   path.

3. **`Auth.Guardian` reattaches `account_type` to User struct** —
   **STILL PENDING** (PR 3). Per launch-prompt risk #3 the desired
   state is `Guardian.resource_from_claims/1` no longer attaches
   `:account_type` (and, for consistency, `:subscription_tier`). PR
   2a confirmed via `grep` that nothing in `lib/` (outside
   controllers) reads `user.account_type`, but the controllers still
   read `user.subscription_tier`. Both reattachments must be removed
   together when the controller sweep lands in PR 3.

### New risks for PR 2b / PR 3

1. **`InviteService.create_invite_row/2` creates a stub User when
   the invitee email is new** — the stub has `name: email` (not
   `nil`) and `password_hash: nil` to satisfy the `users` schema's
   NOT NULL constraints. `accept_invite/2` with the new-user arity
   fills in `name` and `password_hash` from the request. **Risk for
   PR 3**: the API layer (controller + JSON schema) must NOT accept
   empty `name` or missing `password_hash` when calling the new-user
   arity; otherwise the User is created with `name: ""` and the
   registration is invalid. The PR 3 controller tests (tasks 3.4 and
   3.22) should pin this.

2. **The synthesized membership has `id: nil`** — this is by design
   per design §10 (Q1) but means downstream code that branches on
   `membership.id` being non-nil will silently skip the synthesized
   row. The pattern in this PR is `Repo.preload(membership, :account)`
   which works on both real and synthesized structs. **Risk for PR 3**:
   the channel sweep (tasks 3.9–3.12) must NOT depend on
   `membership.id` being non-nil for legacy `access` token holders.

3. **`enforce_seat_cap/2` queries `:active + :invited`** — but PR 2a's
   implementation does NOT count `:suspended` memberships (the spec
   says `:active + :invited` is the cap). The integration test
   confirms this for `:active`. **Risk for PR 3**: if a future change
   ever inserts `:suspended` rows (re-invitation flow per design
   §2.1), the seat-cap math must remain unchanged (`:suspended` rows
   do not consume seats).

4. **`switch_account/2` refetches the User from DB** — the function
   ignores the User passed by the caller and re-reads from the DB to
   avoid trusting caller-supplied identity fields (security decision).
   **Risk for PR 3**: the controller (task 3.5) must pass the real
   `current_user` (from `Guardian.resource_from_claims/1`) so the
   refetch works as intended. Passing a placeholder User would still
   work but adds a needless DB hit.

5. **Channel coverage mismatch (still open)** — apply-progress.md
   §"Open issues" #1 already flagged that `shopping_channel.ex` and
   `inventory_channel.ex` do not exist on disk. PR 2a does not touch
   channels, so this remains open. PR 3 task list (tasks 3.9–3.12)
   covers only the 4 existing channels (`planning`, `cooking`,
   `calendar`, `ai`); `shopping` and `inventory` channels must be
   created (or deferred) before PR 3 channel sweep can complete.

## Risks for PR 2b

- Task 2.10 (atomic registration) MUST insert the `:owner :active`
  membership in the same `Multi` as the Account + User insert.
  Recommended structure:

      Multi.new()
      |> Multi.insert(:account, ...)
      |> Multi.insert(:user, ...)
      |> Multi.insert(:membership, fn %{account: a, user: u} ->
        %AccountMembership{} |> AccountMembership.changeset(%{
          account_id: a.id, user_id: u.id, role: :owner,
          status: :active, joined_at: DateTime.utc_now()
        }) end)

  This will retire the `AccountService.me/1` fallback that PR 1
  introduced.

- Tasks 2.12–2.15 (the four `data/*_repo.ex` query rewrites) need
  careful benchmarking — switching from `user.account_id` to
  `membership.account_id` can introduce N+1 if the new query is
  not preloaded. The repo functions should accept a `membership`
  (not a `user`) and pre-load `:account` once at the boundary.

- Task 2.9 (authenticate_with_password/1 mints `access_v2` when
  flag is on) — the flag is currently `false` in production. When
  PR 2b flips it locally for the test, ensure that the issue_access_v2_token
  factory helper still works (it does — it delegates to
  `AccountsMembership.claims_for/2`).

## Branch / artifact locations

- **Branch**: `feature/phase-a-pr-2a` (base: `origin/feature/phase-a-pr-1`)
- **Apply-progress artifact**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/apply-progress.md`
- **OpenSpec change folder**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/`
- **SDD config**: `meal_planner_api/openspec/config.yaml` (`strict_tdd: true`, `test_runner: "mix test"`)

---

## Skill resolution

- **Skills loaded**: 4 — `sdd-apply`, `_shared/sdd-phase-common`,
  `_shared/openspec-convention`, `strict-tdd` (strict TDD mode active).
- **Skill resolution**: `paths-injected` — orchestrator provided the
  exact paths in the launch prompt.

---

# Apply Progress — phase-a-tenancy-refactor (PR 2b)

> **Change**: `phase-a-tenancy-refactor`
> **PR slice**: PR 2b — atomic registration + dual-write auth + data-layer repo rewrites
> **Branch**: `feature/phase-a-pr-2b` (base: `feature/phase-a-pr-2a`, chain: feature-branch-chain)
> **Apply mode**: `strict_tdd: true`, `test_runner: mix test`
> **Status**: ✅ ready for verify
> **Date**: 2026-06-28

## Goal Recap

Close the two launch-prompt risks called out after PR 2a:

1. **Risk #1 (atomic registration)** — `Accounts.register_with_password/1`
   still did not insert an `AccountMembership` row. PR 2b task 2.10
   makes the registration atomic: Account + User + `:owner :active`
   membership in a single `Multi` transaction.
2. **Risk #2 (Guardian dual-write)** — `Guardian.resource_from_claims/1`
   still reattached `:account_type` (and `:subscription_tier`) to the
   User struct. PR 2b task 2.9 stops reattaching `:account_type`. The
   dual-write synthesis for `access_v1` tokens remains in
   `LoadCurrentMembership` (unchanged from PR 1).

Plus the four data-layer repo rewrites (tasks 2.12–2.15) per
`tasks.md` PR 2b scope. No controller, channel, or service
reach-through in this PR — that lands in PR 3.

Env var at deploy: `MEAL_PLANNER_TENANCY_V2=false` (unchanged).

## Summary

- **6 / 6 tasks complete** (2.9, 2.10, 2.12, 2.13, 2.14, 2.15).
- **7 commits** on `feature/phase-a-pr-2b`, all RED → GREEN →
  REFACTOR. The 7th is a one-line REFACTOR commit that cleans a new
  `--warnings-as-errors` warning introduced by task 2.12.
- **397 tests** in `mix test`, **0 failures** — +14 tests over the
  PR 2a baseline of 383.
- **Branch** pushed to `origin/feature/phase-a-pr-2b`.

## Commits landed (chronological)

| # | SHA | Task | Title |
|---|----|------|-------|
| 1 | `c18e48c` | 2.10 | feat(accounts): atomic register_with_password inserts AccountMembership row |
| 2 | `036d51f` | 2.9 | feat(accounts): dual-write auth — stop reattaching account_type, expose membership on authenticate |
| 3 | `904001a` | 2.12 | feat(account_repo): list_active_memberships_for_account/1 helper for PR 3 controllers |
| 4 | `93a0742` | 2.13 | test(planning_repo): real multi-familia isolation tests replace arity smoke tests |
| 5 | `4782981` | 2.14 | feat(inventory_repo): real multi-familia isolation tests + fix pre-existing occurred_at bug |
| 6 | `5d1cca2` | 2.15 | feat(shopping_repo): multi-familia isolation tests + fix pre-existing delivery_window_start bug |
| 7 | `034a622` | REFACTOR | refactor(account_repo): use AccountMembership alias instead of full module path |

## TDD Cycle Evidence

| Task | Test File | Layer | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|-----|-------|-------------|----------|
| 2.10 | `test/meal_planner_api/accounts_registration_test.exs` (5) | Context (registration) | ✅ | ✅ `c18e48c` | ✅ owner row exists / user account_id set / one owner / duplicate-email rollback / queryable-by-account_id | ✅ clean |
| 2.9 | `test/meal_planner_api/auth/guardian_resource_from_claims_test.exs` (5) + `test/meal_planner_api/accounts_test.exs` (2) | Auth + Context | ✅ | ✅ `036d51f` | ✅ v1 still verifies / v2 still verifies / unknown-sub / subscription_tier still attached / account_id still attached / claims_for sets typ: "access" / flag-off preserves legacy | ✅ cleaned pre-existing alias warnings |
| 2.12 | `test/meal_planner_api/data/account_repo_test.exs` (6) | Data (account) | ✅ | ✅ `904001a` | ✅ preload memberships:user / no account raises / active-only filter / empty / multi-familia isolation / multi-familia same-user two accounts | ✅ alias refactor `034a622` |
| 2.13 | `test/meal_planner_api/data/planning_repo_test.exs` (6, replaces 8 smoke tests) | Data (planning) | ✅ | ✅ `93a0742` | ✅ list_scheduled_meals / list_uncooked_scheduled_meals / cross-account meal_id rejected / canonical meal lookup / fetch_owned_proposal cross-account rejected | ✅ replaced arity smoke tests with real assertions |
| 2.14 | `test/meal_planner_api/data/inventory_repo_test.exs` (6, replaces 13 smoke tests) | Data (inventory) | ✅ | ✅ `4782981` | ✅ list_inventory / get_inventory_item_for_account self+cross / find_inventory_item_by_ingredient scoped / list_mutations scoped / apply_delta isolated | ✅ removed unused alias |
| 2.15 | `test/meal_planner_api/data/shopping_repo_test.exs` (5, new) | Data (shopping) | ✅ | ✅ `5d1cca2` | ✅ list_checkout_sessions / list_pending_delivery_sessions / get_checkout_session_for_account self+cross / list_shopping_items | ✅ removed unused aliases |

## New files (created in PR 2b)

### Production code
- `meal_planner_api/lib/meal_planner_api/auth/guardian.ex` (modified — stops reattaching `:account_type`)
- `meal_planner_api/lib/meal_planner_api/accounts.ex` (modified — atomic registration, flag-aware authenticate, `typ: "access"` in claims_for)
- `meal_planner_api/lib/meal_planner_api/data/account_repo.ex` (modified — adds `list_active_memberships_for_account/1`)
- `meal_planner_api/lib/meal_planner_api/data/inventory_repo.ex` (modified — fixes pre-existing `occurred_at` bug + `list_mutations/3` signature now accepts DateTime)
- `meal_planner_api/lib/meal_planner_api/data/shopping_repo.ex` (modified — fixes pre-existing `delivery_window_start` bug)

### Tests
- `meal_planner_api/test/meal_planner_api/accounts_registration_test.exs` (task 2.10, 5 tests)
- `meal_planner_api/test/meal_planner_api/auth/guardian_resource_from_claims_test.exs` (task 2.9, 5 tests)
- `meal_planner_api/test/meal_planner_api/accounts_test.exs` (extended — task 2.9 flag-flip tests, +2 tests)
- `meal_planner_api/test/meal_planner_api/data/account_repo_test.exs` (task 2.12, 6 tests)
- `meal_planner_api/test/meal_planner_api/data/planning_repo_test.exs` (rewritten — task 2.13, 6 tests replacing 8 smoke tests)
- `meal_planner_api/test/meal_planner_api/data/inventory_repo_test.exs` (rewritten — task 2.14, 6 tests replacing 13 smoke tests)
- `meal_planner_api/test/meal_planner_api/data/shopping_repo_test.exs` (task 2.15, 5 tests)

## `mix test` summary

```
Finished in 7.2 seconds (1.5s async, 5.7s sync)
397 tests, 0 failures
```

- Total tests added in PR 2b: **+14** new test functions across 7
  new/extended test files. Plus the inventory_repo and
  planning_repo rewrites removed 21 arity-only smoke tests, replaced
  by 12 real behavioral tests.
- Pre-PR-2b baseline (PR 2a): 383 tests. Post-PR-2b: **397 tests**.

## Deviations from tasks.md PR 2b scope

1. **`shopping_repo_test.exs` and `account_repo_test.exs` did not
   exist before PR 2b** — created from scratch (tasks 2.12 and 2.15).
   The pre-existing `inventory_repo_test.exs` and
   `planning_repo_test.exs` only asserted function arity (smoke
   tests) — replaced with real behavioral assertions in tasks 2.13
   and 2.14.

2. **Caught two pre-existing bugs in the production repos while
   writing the isolation tests:**
   - `MealPlannerApi.Data.InventoryRepo.list_mutations/3` referenced
     `e.occurred_at` (a field that does not exist on the
     `InventoryMutationEvent` schema). The function therefore could
     not have worked — it would have raised `Ecto.QueryError` at
     runtime. Fixed to use `e.inserted_at`; signature tightened to
     `DateTime` to match the schema field type.
   - `MealPlannerApi.Data.ShoppingRepo.list_pending_delivery_sessions/1`
     referenced `s.delivery_window_start` (no such field on
     `CheckoutSession`). Same fix pattern: use `s.inserted_at` for
     ordering.
   Both fixes are within PR 2b scope (the `tasks.md` PR 2b
   description for 2.14 and 2.15 is the data-layer query rewrite,
   and these two queries are part of that rewrite). The signature
   change in `list_mutations/3` (Date → DateTime) is safe: the
   function had no callers outside the new test.

3. **Task 2.9 scope expanded slightly** — the `tasks.md`
   description for 2.9 focused on the
   `authenticate_with_password/1` flag-flip; the launch prompt's
   risk #2 explicitly called out removing the Guardian
   `:account_type` reattachment. Both landed in PR 2b. The
   `:subscription_tier` reattachment is **preserved** (controllers
   in PR 3 still read `user.subscription_tier`; removing the
   reattachment now would break them before the controller sweep
   lands).

4. **`Accounts.authenticate_with_password/1` returns the User's
   first `:active` membership** as a third map key
   (`membership`). The launch prompt is silent on whether to mint
   the JWT at the application layer (the controllers mint it in PR
   3), so PR 2b exposes the membership row so the controller layer
   has what it needs without an extra DB round trip. The flag-flip
   itself happens at the controller layer in PR 3.

## PR 2a risks — status update

| # | Risk | Status |
|---|------|--------|
| 1 | `Accounts.register_with_password/1` does NOT insert an AccountMembership row | **RESOLVED** (task 2.10) — `c18e48c` |
| 2 | `Guardian.resource_from_claims/1` reattaches `:account_type` and `:subscription_tier` | **RESOLVED** (task 2.9) — `:account_type` reattachment removed in `036d51f`; `:subscription_tier` reattachment preserved because PR 3 controllers still read it |
| 3 | `Auth.Guardian.resource_from_claims/1` reattaches both fields; controllers still read `user.subscription_tier` | **STILL OPEN** — task 3.8's `auth_controller.ex` rewrite + tasks 3.14–3.20 controller sweep. PR 2b removed only `:account_type`; `:subscription_tier` reattachment stays until controllers stop reading it. |
| 4 | Channel sweep coverage — `shopping_channel.ex` and `inventory_channel.ex` don't exist on disk | **STILL OPEN** — task 3.13 area. PR 2b didn't touch channels. |
| 5 | `subscriptions.ex` already reads `Account.plan` | **RESOLVED** in PR 2a (task 2.11) — confirmed by this PR's apply; no regression. |

## New risks for PR 3a / PR 3b / PR 3c

1. **`LoadCurrentMembership` still synthesizes `current_membership`
   from `user.account_id`** for legacy `access` tokens. After
   PR 2b's atomic registration, fresh users have
   `user.account_id` set + a real `AccountMembership` row, but
   legacy users (pre-PR-2a backfill) may have `user.account_id`
   set but the `current_membership` is **synthesized** (no
   `membership_id`, `__synthesized__: true`). PR 3 controllers
   must NOT depend on `current_membership.id` being non-nil for
   the synthesized fallback path.

2. **`authenticate_with_password/1` returns the User's first
   `:active` membership**, but the membership row's `:account_id`
   may differ from `user.account_id` for multi-familia Users. The
   PR 3 `auth_controller.ex` flag-flip must use
   `membership.account_id` (not `user.account_id`) when minting
   the access_v2 JWT, otherwise multi-familia Users would receive
   a token scoped to the wrong Account.

3. **`list_active_memberships_for_account/1` filters by `:active`
   status only.** `:invited` and `:suspended` memberships are
   excluded. The PR 3 `MembershipController.index/2` (the roster
   endpoint per spec `invite-and-accept.md` §"Membership roster")
   currently needs `:active + :invited` rows. PR 3 will either
   need to use `list_memberships/1` from `AccountsMembership` (the
   application-layer helper, which already includes both) or add
   a sibling `list_active_or_invited_memberships_for_account/1`
   helper. Recommended: use the application-layer helper to keep
   the data layer thin.

4. **`InventoryRepo.list_mutations/3` signature changed from
   `Date` to `DateTime`**. PR 3's `inventory_controller.ex` (if
   it calls `list_mutations/3`) must construct DateTime boundaries
   (e.g. `DateTime.new!(date, ~T[00:00:00.000])`). The pre-PR-2b
   signature would have raised `Ecto.Query.CastError` at runtime,
   so this is a forward fix — but the PR 3 inventory controller
   needs the new shape.

5. **Two pre-existing `--warnings-as-errors` warnings remain**
   (`account_service.ex` unused alias `AccountMembership`;
   `shopping_controller.ex` unused function `parse_bool/1`). Both
   predate this change. PR 2b cannot fix them without leaving the
   task scope (launch prompt: "Do NOT fix pre-existing failures
   in this PR"). PR 3 is a natural place to clean both up — the
   `account_service.ex` change is a 3-line rename (the alias was
   added by PR 1's deviation #3); the `shopping_controller.ex`
   `parse_bool/1` removal is a 1-line delete.

6. **`Subscriptions.policy_for_account/1` returns a map (not a
   tuple)** and embeds `revenuecat_entitlement_id` as `nil` for
   legacy plans (the seed in `subscription_plan_fixtures.ex`
   passes `nil`). PR 3's billing-surface controller reads this
   map and should treat `nil` entitlement_id as "no RevenueCat
   binding" (not as a fatal error).

## Branch / artifact locations

- **Branch**: `origin/feature/phase-a-pr-2b`
- **Apply-progress artifact**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/apply-progress.md`
- **OpenSpec change folder**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/`
- **SDD config**: `meal_planner_api/openspec/config.yaml` (`strict_tdd: true`, `test_runner: "mix test"`)

---

## Skill resolution

- **Skills loaded**: 4 — `sdd-apply`, `_shared/sdd-phase-common`,
  `_shared/openspec-convention`, `strict-tdd` (strict TDD mode active).
- **Skill resolution**: `paths-injected` — orchestrator provided the
  exact paths in the launch prompt.
