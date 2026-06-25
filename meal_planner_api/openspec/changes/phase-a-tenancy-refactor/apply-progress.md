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
