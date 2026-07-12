# Tasks — phase-a-tenancy-refactor

> **Change**: `phase-a-tenancy-refactor` — tenancy refactor + dual-write Guardian.
> **Owner sub-project**: `meal_planner_api`.
> **Upstream artifacts**: [`proposal.md`](proposal.md), [`design.md`](design.md), [`specs/`](specs/) (6 specs).
> **PRD**: [vicenzogiordana/myfood#1](https://github.com/vicenzogiordana/myfood/issues/1) — Phase A.
> **TDD mode**: `strict_tdd: true`, `test_runner: "mix test"`, `max_changed_lines: 400` (chained PRs required).
> **Delivery strategy** (cached at session preflight C1): **ask-always** — the orchestrator confirms chain strategy at `sdd-apply` time per task.

## Overview

- **Total tasks**: 55 (per-PR subtotals: 14 / 16 / 25 — see "Task Count Summary")
- **Total estimated lines**: +2,370 added, -307 modified (~2,677 net diff including substantial test code; production code is closer to the proposal's ~1,500 forecast)
- **Forecasted review budget risk per PR**:
  - PR 1: **Medium** (~628 net diff — at the 400-line threshold, safe as one PR)
  - PR 2: **High** (~694 net diff — exceeds 400; natural sub-PR split documented in PR 2 subtotal)
  - PR 3: **High** (~741 net diff — exceeds 400; natural sub-PR split documented in PR 3 subtotal)
- **Phases**: 3 PRs (chained, feature-branch chain per proposal §"Approach")
- **Delivery strategy**: `ask-always` (per session preflight C1)
- **Chained PR strategy**: `ask-always` (the orchestrator will confirm at `sdd-apply` time)

```text
Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium (PR 1) / High (PR 2) / High (PR 3)
```

### PR strategy (matches proposal §"Approach — Three Chained PRs")

| PR | Scope (forecast) | Base branch | Env var on merge | What lands |
|---|---|---|---|---|
| 1 | ~400 LOC | `main` | `MEAL_PLANNER_TENANCY_V2=false` (unchanged) | 4 migrations, `AccountMembership` schema, `Account`/`User` schema rewrites, factory macros, `LoadCurrentMembership` plug, migration sanity test |
| 2 | ~520 LOC | PR 1 branch | unchanged | `AccountsMembership` context, `InviteService`, `Subscriptions.policy_for_account/1` rewrite, `data/*_repo.ex` query rewrites, `Accounts` registration atomicity |
| 3 | ~600 LOC | PR 2 branch | **flip to** `MEAL_PLANNER_TENANCY_V2=true` after deploy | 3 new controllers, `auth_controller.ex` rewrite, channel sweep (4 channels), factory extensions, controller test sweep, `ARCHITECTURE.md` update, `FRONTEND_INTEGRATION.md` update |

### Test conventions (project-wide)

- **RED → GREEN → REFACTOR** for every task. Acceptance criteria explicitly demand a failing test first.
- Use `start_supervised!/1` (per `meal_planner_api/AGENTS.md`), never `Process.sleep/1` / `Process.alive?/1`.
- HTTP requests: use `Req` (already included), not `httpoison` / `tesla` / `httpc`.
- Run scoped verification: `mix test test/meal_planner_api/persistence/...` then `mix precommit` before merge.
- `:auth`-piped route tests must drive both token types (`access` / `access_v2`) per design §8.4.

---

## PR 1 — DB migration + `AccountMembership` schema + dual-write Guardian

**Goal**: land the data model and the dual-write Guardian so PR 2 can build use cases against real shapes without breaking `access_v1` clients. No controller reach-through.
**Env var at deploy**: `MEAL_PLANNER_TENANCY_V2=false` (default — `access_v1` is the only minted type).
**Forecast**: ~400 LOC (Medium risk; lands at the 400-line threshold).

### Task 1.1 — Create `account_memberships` table

- **Files**:
  - `meal_planner_api/priv/repo/migrations/2026XXXX_create_account_memberships.exs` (new)
  - `meal_planner_api/test/support/migration_shape_test.exs` (new, RED first)
- **Type**: test-first (red→green)
- **Description**: DDL per design §2.1 — `id :binary_id`, FKs to `accounts` / `users` (`on_delete: :delete_all` for both), `role`/`, `:string` with CHECK constraints, `:string` `status` with CHECK constraint, `invited_by_user_id` (`on_delete: :nilify_all`), `invite_token_hash`, `invite_expires_at`, `joined_at`, `timestamps`. Three lookup indexes (`user_id, account_id`), `(account_id, status)`, `(user_id, status)`) plus the partial unique index `account_memberships_active_account_user_unique_index` on `(account_id, user_id) WHERE status = 'active'`. Index names aligned with the existing migration history (`meal_planner_api/priv/repo/migrations/20260322090000_create_accounts_and_users.exs`).
- **Acceptance criteria**:
  - [ ] test added at `test/support/migration_shape_test.exs` asserting the table, the CHECK constraints, and the partial unique index exist (RED — migration not yet created)
  - [ ] migration file written; `mix ecto.migrate` runs GREEN
  - [ ] test asserts `INSERT … ON CONFLICT` of a second `:active` row for the same `(account, user)` raises `unique_violation`
- **Estimated lines**: +60 / -0
- **Depends on**: none

### Task 1.2 — Migrate `accounts.account_type` → `accounts.plan` + seed `:family_6` / `:trial`

- **Files**:
  - `meal_planner_api/priv/repo/migrations/2026XXXX_alter_accounts_to_plan_enum.exs` (new)
  - `meal_planner_api/test/support/migration_shape_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `ALTER TABLE accounts DROP COLUMN account_type`, `ADD COLUMN plan :string NOT NULL DEFAULT 'individual'`, CHECK constraint `plan IN ('individual', 'family_4', 'family_6', 'trial')`. Data migration: any legacy `account_type: :group` rows → `plan: 'family_4'` (per design §2.2). Seed two `subscription_plans` rows (`name: 'family_6'`, `max_users: 6`, `max_planning_days: 30`, `revenuecat_entitlement_id: 'family_6'`; same for `'trial'`); existing `:individual` and `:family_4` rows preserved via `on_conflict: :nothing`. Reuse the existing `SubscriptionPlan` changeset.
- **Acceptance criteria**:
  - [ ] test asserts all four `subscription_plans.name` rows exist after migration (RED)
  - [ ] migration runs; all four rows present; legacy `:group` data is rewritten to `:family_4`; CHECK constraint rejects unknown plan values
  - [ ] `:group` value in `account_type` column is gone (column dropped)
- **Estimated lines**: +70 / -5
- **Depends on**: 1.1

### Task 1.3 — Make `users.account_id` nullable

- **Files**:
  - `meal_planner_api/priv/repo/migrations/2026XXXX_make_user_account_id_nullable.exs` (new)
  - `meal_planner_api/test/support/migration_shape_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Per decision 5.1, relax `users.account_id` to nullable for the dual-write window. `modify :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: true`. Down migration restores `NOT NULL` after backfilling from the membership rows (backfill-from-membership SQL ships with this migration's down, not its up — the down only fires in catastrophic rollback).
- **Acceptance criteria**:
  - [ ] test inserts a `User` row with `account_id: nil` and asserts it persists (RED — column is NOT NULL today)
  - [ ] migration applied; test GREEN
  - [ ] down migration restores NOT NULL after a backfill SQL runs in the down step
- **Estimated lines**: +30 / -2
- **Depends on**: 1.1

### Task 1.4 — Backfill `account_memberships` from `users.account_id` + invariant function

- **Files**:
  - `meal_planner_api/priv/repo/migrations/2026XXXX_add_account_memberships_backfill.exs` (new)
  - `meal_planner_api/test/support/migration_shape_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Design §2.4 batched `DO $$ … LOOP … END $$` backfill in 1,000-row batches with `pg_sleep(0.05)` and `FOR UPDATE SKIP LOCKED`. Maps each legacy `(user, account)` to one `:active` `:owner` membership with `joined_at = users.inserted_at`. Defines `CREATE OR REPLACE FUNCTION check_account_membership_invariants()` (design §2.5) and invokes it at the end of the migration's transaction. Raises if (a) any legacy `(user, account)` lacks an `:active` membership, (b) any Account has no `:owner`, (c) any Account has >1 `:owner`.
- **Acceptance criteria**:
  - [ ] test seeds 3 legacy `users` with `account_id`s, runs the migration in a transaction, then asserts `check_account_membership_invariants()` returns `void` and one `:active :owner` membership exists per user (RED — migration not yet written)
  - [ ] migration runs; assertion GREEN
  - [ ] test deliberately inserts a user with a missing membership and asserts the function raises (`backfill_invariant_failed`) (RED → GREEN)
  - [ ] test runs `mix ecto.rollback` then `mix ecto.migrate` and re-asserts invariants
- **Estimated lines**: +90 / -3
- **Depends on**: 1.1, 1.2, 1.3

### Task 1.5 — `AccountMembership` Ecto schema

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/persistence/accounts/account_membership.ex` (new)
  - `meal_planner_api/test/meal_planner_api/persistence/accounts/account_membership_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: `schema "account_memberships"` with the columns from migration 1.1. `Ecto.Enum` for `role` (`:owner | :member`) and `status` (`:active | :invited | :suspended`). `belongs_to :account`, `belongs_to :user`, `belongs_to :invited_by, ...:User, foreign_key: :invited_by_user_id`. Changeset: required `account_id`, `user_id`, `role`, `status`; validates enum membership; unique_constraint on `invite_token_hash` (allow_nil). **No tenancy logic** (Clean Architecture: schema is dumb data).
- **Acceptance criteria**:
  - [ ] test asserts valid changeset for `:active :owner` (RED — schema missing)
  - [ ] test asserts invalid changeset for unknown role / status
  - [ ] test asserts FK constraints surface as `Ecto.Changeset`'s errors when account_id / user_id is bogus
  - [ ] schema file written; all tests GREEN
- **Estimated lines**: +70 / -0
- **Depends on**: 1.1

### Task 1.6 — `Account` schema: drop `account_type`, add `plan`, swap `has_many`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/persistence/accounts/account.ex` (modify)
  - `meal_planner_api/test/meal_planner_api/persistence/accounts/account_test.exs` (new or extend)
- **Type**: test-first (red→green)
- **Description**: Drop `:account_type` field; add `:plan` `Ecto.Enum` with `:individual | :family_4 | :family_6 | :trial`. Drop `has_many :users`; add `has_many :memberships, MealPlannerApi.Persistence.Accounts.AccountMembership`. Keep `belongs_to :subscription_plan` if present, otherwise leave FK as-is and resolve via `subscription_plans` (design §2.6 — Q10).
- **Acceptance criteria**:
  - [ ] test asserts `Account.changeset(%{}, %{plan: :family_4})` is valid (RED — `plan` field absent)
  - [ ] test asserts `Account.changeset(%{}, %{plan: :unknown})` fails enum validation
  - [ ] test asserts the new `has_many :memberships` preloads without error
  - [ ] schema file updated; all tests GREEN; existing tests still pass (no `:account_type` references in app code — verified by `grep`)
- **Estimated lines**: +20 / -10
- **Depends on**: 1.2, 1.5

### Task 1.7 — `User` schema: nullable `account_id`, add `has_many :memberships`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/persistence/accounts/user.ex` (modify)
  - `meal_planner_api/test/meal_planner_api/persistence/accounts/user_test.exs` (new or extend)
- **Type**: test-first (red→green)
- **Description**: Make `:account_id` nullable in the schema (`field :account_id, :binary_id` — no longer required). Add `has_many :memberships, MealPlannerApi.Persistence.Accounts.AccountMembership`. Drop `:role` if it duplicates `AccountMembership.role` (per proposal §Stream A — keep `:role` for now; treat as legacy until 1.8 removes it).
- **Acceptance criteria**:
  - [ ] test asserts `User.changeset(%{}, %{email: "x@y", account_id: nil})` is valid (RED — schema requires account_id today)
  - [ ] test asserts preloading `memberships` works
  - [ ] schema file updated; tests GREEN; existing tests still pass
- **Estimated lines**: +15 / -5
- **Depends on**: 1.3, 1.5

### Task 1.8 — Factory macro `create_user_with_memberships/2`

- **Files**:
  - `meal_planner_api/test/support/factory.ex` (extend)
  - `meal_planner_api/test/support/factory_helpers_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: Per design §8.2 (Q6) — add `user_with_memberships/2` that accepts `[{account_attrs, role}, ...]` and inserts a User + N Accounts + N `:active :owner | :member` memberships. Returns `User` preloaded with `memberships: :account`. Existing macros preserved.
- **Acceptance criteria**:
  - [ ] test asserts `user_with_memberships(%{email: "x@y"}, [{ %{plan: :family_4, name: "F"}, :owner }, { %{plan: :individual, name: "P"}, :member }])` returns a User with 2 memberships (RED — macro not yet written)
  - [ ] macro written; test GREEN
  - [ ] test asserts preloading round-trips Account.plan enum values
- **Estimated lines**: +40 / -0
- **Depends on**: 1.5, 1.6

### Task 1.9 — Factory macro `issue_access_v2_token/2`

- **Files**:
  - `meal_planner_api/test/support/factory.ex` (extend)
  - `meal_planner_api/test/support/factory_helpers_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Per design §8.2 — `issue_access_v2_token(user, membership)` calls `AccountsMembership.claims_for/2` (which does not exist yet — stub it inside the task as a private helper that builds the `access_v2` claim map by hand using `Account.plan`, then promote to `AccountsMembership.claims_for/2` in PR 2 task 2.1). Encodes via `Guardian.encode_and_sign/3` with `token_type: "access"`. Returns the JWT string.
- **Acceptance criteria**:
  - [ ] test decodes the token via `Guardian.decode_and_verify/2` and asserts `claims["typ"] == "access_v2"`, `claims["membership_id"] == membership.id`, `claims["account_id"] == account.id`, `claims["plan"] == "family_4"` (RED)
  - [ ] helper written; test GREEN
- **Estimated lines**: +25 / -0
- **Depends on**: 1.5, 1.8

### Task 1.10 — `LoadCurrentMembership` plug

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/plugs/load_current_membership.ex` (new)
  - `meal_planner_api/lib/meal_planner_api_web/plugs/load_current_membership_socket.ex` (new, sibling for socket callsites — small wrapper)
  - `meal_planner_api/test/meal_planner_api_web/plugs/load_current_membership_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: Plug + sibling for the WebSocket. Reads `conn.assigns.current_user` and JWT claims from `Guardian.Plug.Pipeline`. If `claims["typ"] == "access_v2"` → load `AccountMembership` by `claims["membership_id"]`, preload `:account`. If missing/invalid → halt with `401 unauthorized`, body `%{error: "membership_id_required"}`. If `claims["typ"] == "access"` (legacy) → synthesize `%AccountMembership{id: nil, account_id: user.account_id, role: user.role, status: :active, joined_at: nil, __synthesized__: true}` after reading `Account.plan`. No row inserted. Exposes `LoadCurrentMembership.membership_from_socket/1` (Q8).
- **Acceptance criteria**:
  - [ ] test issues an `access_v2` token, hits a `:auth`-piped conn, asserts `conn.assigns.current_membership.id == membership.id` and `account_id` matches (RED)
  - [ ] test issues a legacy `access` token (with `account_id` in claim), asserts the synthesized membership has `__synthesized__: true` and `account_id == user.account_id` (RED)
  - [ ] test issues an `access_v2` token with no `membership_id`, asserts halt with `401 membership_id_required` (RED)
  - [ ] plug written; all tests GREEN
- **Estimated lines**: +95 / -0
- **Depends on**: 1.5, 1.9

### Task 1.11 — `AuthPipeline` accepts both token types

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/auth_pipeline.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/auth_pipeline_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: `Guardian.Plug.VerifyHeader` currently uses `claims: %{"typ" => "access"}`. Change to `claims: %{"typ" => "access"}` AND register an additional VerifyHeader step that also accepts `"access_v2"`. Add `MealPlannerApiWeb.Plugs.LoadCurrentMembership` to the pipeline (after `LoadResource`). Reject unknown `typ` with `401 unauthorized, reason: "unsupported_token_type"`.
- **Acceptance criteria**:
  - [ ] test asserts an `access_v1` token verifies (RED → GREEN)
  - [ ] test asserts an `access_v2` token verifies and `current_membership` is populated (RED → GREEN)
  - [ ] test asserts an `access_v3` token halts with `unsupported_token_type` (RED → GREEN)
- **Estimated lines**: +25 / -5
- **Depends on**: 1.10

### Task 1.12 — `UserSocket.connect/3` populates `current_membership`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/user_socket.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/user_socket_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: `connect/3` reads `params["token"]` (existing), runs `Guardian.resource_from_token/1` for `current_user` (existing), then calls `LoadCurrentMembership.call_for_socket/2` (the sibling from task 1.10) to assign `current_membership`. On failure returns `:error`.
- **Acceptance criteria**:
  - [ ] test connects with an `access_v2` token and asserts `socket.assigns.current_membership.id == membership.id` (RED)
  - [ ] test connects with an `access_v1` token and asserts `current_membership.__synthesized__ == true` (RED)
  - [ ] change applied; tests GREEN
- **Estimated lines**: +20 / -2
- **Depends on**: 1.10

### Task 1.13 — Migration sanity test (dedicated checkpoint)

- **Files**:
  - `meal_planner_api/test/support/migration_sanity_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: Per design §8.3 — runs `mix ecto.drop && mix ecto.create && mix ecto.migrate` from a clean DB; asserts all four `subscription_plans` rows exist; inserts fixture `users` + `accounts` matching the pre-Phase-A shape; runs `check_account_membership_invariants()` and asserts zero violations. Then `mix ecto.rollback` to the pre-Phase-A snapshot, re-runs `migrate`, re-asserts. (Implementation: pure test code using `Mix.Task.run/2`; no migration files of its own.)
- **Acceptance criteria**:
  - [ ] test passes GREEN on a fresh DB after PR 1's four migrations land
  - [ ] test passes GREEN after a rollback + re-migrate cycle
- **Estimated lines**: +55 / -0
- **Depends on**: 1.1, 1.2, 1.3, 1.4

### Task 1.14 — Dual-write token issuance test (dedicated checkpoint)

- **Files**:
  - `meal_planner_api/test/meal_planner_api/auth/guardian_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: Per design §8.4 — encode two JWTs via `Guardian` directly: one with `typ: "access"` (manual claim map) and one with `typ: "access_v2"` (also manual, including `membership_id`). Decode both and assert the claim sets match design §3.1 and §3.2 exactly. Also assert an `access_v2` token without `membership_id` triggers `Guardian.decode_and_verify` but is rejected by `LoadCurrentMembership` (this part delegates to task 1.10's test). This task proves the JWT shape independent of any controller — it is the bridge between spec §3 and the pipeline in 1.11.
- **Acceptance criteria**:
  - [ ] test asserts `access_v1` claim set per design §3.1
  - [ ] test asserts `access_v2` claim set per design §3.2 (including `membership_id`, `plan`, `role`, `status`)
  - [ ] test asserts an unknown `typ` is rejected by the pipeline (delegated to task 1.11)
- **Estimated lines**: +45 / -0
- **Depends on**: 1.5, 1.10

**PR 1 subtotal**: +660 added, -32 modified, 14 tasks
**PR 1 review budget risk**: **Medium** (~628 net diff vs. 400-line budget — at threshold, but the migration SQL is dense and the schema surface is narrow; one PR is appropriate per proposal §"Approach — PR 1")

---

## PR 2 — `AccountsMembership` context rewrite (no controller reach-through)

**Goal**: ship the use-case layer (`AccountsMembership`, `InviteService`, `Subscriptions` rewrite, `data/*_repo.ex` query rewrites). Controllers in this PR still read `current_user.account_id` — `current_membership` is synthesized by the pipeline (PR 1) and is available but unused at the controller layer.
**Env var at deploy**: `MEAL_PLANNER_TENANCY_V2=false` (unchanged).
**Forecast**: ~520 LOC (High risk; exceeds 400-line budget by ~120 LOC — the orchestrator may split into two sub-PRs at apply time if maintainers push back).

### Task 2.1 — `AccountsMembership.claims_for/2`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/accounts_membership.ex` (new, scaffold)
  - `meal_planner_api/test/meal_planner_api/accounts_membership_claims_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: Public function `claims_for(user, membership) :: %{sub, typ: "access_v2", membership_id, account_id, role, plan, status, email, name, iat, exp}` per design §3.2. Preloads membership.account if needed. Used by the `issue_access_v2_token/2` factory helper (task 1.9) and by `auth_controller.ex` in PR 3.
- **Acceptance criteria**:
  - [ ] test asserts the returned map has every key from design §3.2 (RED — function not yet written)
  - [ ] function written; test GREEN
  - [ ] test asserts `plan` is the string form (`"family_4"`, not `:family_4`)
- **Estimated lines**: +30 / -0
- **Depends on**: 1.5, 1.6

### Task 2.2 — `AccountsMembership.current_membership/2`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/accounts_membership.ex` (extend)
  - `meal_planner_api/test/meal_planner_api/accounts_membership_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: `current_membership(user, claims) :: AccountMembership.t() | nil`. If `claims["typ"] == "access_v2"` → load by `membership_id`. If `claims["typ"] == "access"` → synthesize from `user.account_id` + `user.role` + `Account.plan` (Q1 marker `__synthesized__: true`). Returns `nil` if `user` is `nil` or the membership cannot be resolved.
- **Acceptance criteria**:
  - [ ] test asserts a real membership is returned for `access_v2` claims (RED)
  - [ ] test asserts a synthesized membership is returned for legacy `access` claims with `__synthesized__: true` (RED)
  - [ ] test asserts `nil` for an `access_v2` claim with no matching membership
  - [ ] function written; tests GREEN
- **Estimated lines**: +40 / -0
- **Depends on**: 2.1

### Task 2.3 — `AccountsMembership.invite/3` (owner invites email)

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/accounts_membership.ex` (extend)
  - `meal_planner_api/test/meal_planner_api/accounts_membership_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `invite(account, inviter_membership, email) :: {:ok, %{token: plaintext, expires_at, membership}} | {:error, atom}`. Wraps `InviteService.mint_token/0` (task 2.7) and `enforce_seat_cap/2` (task 2.6). Refuses if `inviter_membership.role != :owner` (`:not_owner`), seat at cap (`:seat_cap_reached`), or invitee already has an `:invited` or `:active` membership (`:already_invited`). Runs inside a `Repo.transaction/1` with `SELECT … FOR UPDATE` on the Account row. Errors normalized per spec `invite-and-accept`.
- **Acceptance criteria**:
  - [ ] test asserts successful insert with plaintext token returned once and hash stored (RED)
  - [ ] test asserts `:not_owner` when a `:member` calls
  - [ ] test asserts `:seat_cap_reached` when the Account has 4 `:active` memberships and plan is `:family_4`
  - [ ] test asserts `:already_invited` when an `:invited` membership already exists for the email
  - [ ] function written; tests GREEN
- **Estimated lines**: +70 / -0
- **Depends on**: 2.1, 2.6, 2.7

### Task 2.4 — `AccountsMembership.accept_invite/2`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/accounts_membership.ex` (extend)
  - `meal_planner_api/test/meal_planner_api/accounts_membership_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `accept_invite(plaintext_token, current_user_or_attrs) :: {:ok, %{user, account, membership, claims}} | {:error, atom}`. Looks up membership by `invite_token_hash`, refuses if expired (`:invite_token_expired`) or already used (`:invite_token_used`) or no longer `:invited`. If `:invited` → flips to `:active`, sets `joined_at`, nulls `invite_token_hash` + `invite_expires_at`. If `current_user_or_attrs` is `nil` → creates a new `User` from the membership's email and provided attrs. Calls `claims_for/2` (task 2.1) to return the new `access_v2` claim map.
- **Acceptance criteria**:
  - [ ] test asserts existing User acceptance flips status and invalidates the token (RED)
  - [ ] test asserts new User acceptance creates the user and flips status (RED)
  - [ ] test asserts replay (second accept with same plaintext) returns `:invite_token_used`
  - [ ] test asserts expired token returns `:invite_token_expired`
  - [ ] function written; tests GREEN
- **Estimated lines**: +80 / -0
- **Depends on**: 2.1, 2.7

### Task 2.5 — `AccountsMembership.list_memberships/1` + `remove_member/2` + `leave/1`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/accounts_membership.ex` (extend)
  - `meal_planner_api/test/meal_planner_api/accounts_membership_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Three sibling functions:
  - `list_memberships(account) :: [%AccountMembership{}, …]` ordered `role ASC, joined_at ASC` (owner first). Preloads `:user`.
  - `remove_member(account, target_user_id, actor_membership) :: :ok | {:error, :not_owner | :cannot_remove_owner | :membership_not_found}`. Refuses when `actor_membership.role != :owner`. Refuses when target is the owner. Hard-deletes (Q3).
  - `leave(account, actor_membership) :: :ok | {:error, :cannot_leave_owned_account | :not_a_member}`. Refuses when `actor_membership.role == :owner`.
- **Acceptance criteria**:
  - [ ] test asserts list returns rows ordered owner-first (RED)
  - [ ] test asserts remove refuses for non-owner actor
  - [ ] test asserts remove refuses for owner target
  - [ ] test asserts leave refuses for owner
  - [ ] functions written; tests GREEN
- **Estimated lines**: +60 / -0
- **Depends on**: 2.2

### Task 2.6 — `AccountsMembership.seat_usage/1` + `enforce_seat_cap/2`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/accounts_membership.ex` (extend)
  - `meal_planner_api/test/meal_planner_api/accounts_membership_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `seat_usage(account) :: %{active: N, invited: M, capacity: C}` (counts `:active + :invited`, capacity from `Account.plan` per spec `account-membership.md` §"Seat cap"). `enforce_seat_cap(account, count_to_add \\ 1) :: :ok | {:error, :seat_cap_reached}`. Called inside the invite transaction (task 2.3) under `SELECT … FOR UPDATE`.
- **Acceptance criteria**:
  - [ ] test asserts capacity for `:family_4` is 4, `:family_6` is 6, `:individual` is 1, `:trial` is 6 (RED)
  - [ ] test asserts `enforce_seat_cap/2` returns `:seat_cap_reached` when `active + invited + count_to_add > capacity`
  - [ ] functions written; tests GREEN
- **Estimated lines**: +40 / -0
- **Depends on**: 1.6

### Task 2.7 — `InviteService` (token mint/verify/consume)

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/services/invite_service.ex` (new)
  - `meal_planner_api/test/meal_planner_api/services/invite_service_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: Three pure functions. `mint_token/0 :: {plaintext, hash}` — 32 bytes from `:crypto.strong_rand_bytes/1`, URL-safe base64 (no padding) → ~43-char string, `hash = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)`. `hash_token/1` for external callers. `verify_and_consume/2` — `(plaintext, account_id) :: {:ok, %AccountMembership{}} | {:error, :invite_token_used | :invite_token_expired | :invite_token_unknown}`. Single-use: inside the transaction, sets `invite_token_hash: nil`, `invite_expires_at: nil`. Expiry: 7 days from mint.
- **Acceptance criteria**:
  - [ ] test asserts mint produces a plaintext ≥ 40 chars and hash is 64 hex chars (RED)
  - [ ] test asserts `verify_and_consume/2` flips the row and a second call returns `:invite_token_used`
  - [ ] test asserts an expired token returns `:invite_token_expired`
  - [ ] test asserts a wrong-plaintext lookup returns `:invite_token_unknown`
  - [ ] service written; tests GREEN
- **Estimated lines**: +55 / -0
- **Depends on**: 1.5

### Task 2.8 — `AccountsMembership.switch_account/2`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/accounts_membership.ex` (extend)
  - `meal_planner_api/test/meal_planner_api/accounts_membership_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `switch_account(user, target_membership_id) :: {:ok, %{user, account, membership, claims}} | {:error, :not_your_membership | :membership_not_active | :membership_not_found}`. Loads membership by id; refuses if `membership.user_id != user.id`. Refuses if `status != :active`. Returns the claim map from `claims_for/2` (task 2.1).
- **Acceptance criteria**:
  - [ ] test asserts a multi-familia User can switch to a second `:active` membership (RED)
  - [ ] test asserts switch to another User's membership returns `:not_your_membership`
  - [ ] test asserts switch to a `:suspended` membership returns `:membership_not_active`
  - [ ] function written; tests GREEN
- **Estimated lines**: +35 / -0
- **Depends on**: 2.1

### Task 2.9 — Rewrite `Accounts.authenticate_with_password/1` to issue `access_v2` only when flag is on

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/accounts.ex` (modify)
  - `meal_planner_api/test/meal_planner_api/accounts_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `authenticate_with_password/1` consults `Application.get_env(:meal_planner_api, :tenancy_v2_only, false)` (env: `MEAL_PLANNER_TENANCY_V2`). If off → keep the existing `access` claim path. If on → call `AccountsMembership.claims_for/2` (task 2.1) with the User's first `:active` membership (newly inserted by `register_with_password/1` in task 2.10) and mint `access_v2`. Behavior of the `accounts.ex` `claims_for/2` (legacy `access_v1` builder) is preserved unchanged for the off path.
- **Acceptance criteria**:
  - [ ] test asserts `MEAL_PLANNER_TENANCY_V2=false` mints `access_v1` (existing behavior, regression test)
  - [ ] test asserts `MEAL_PLANNER_TENANCY_V2=true` mints `access_v2` with `membership_id` claim (RED)
  - [ ] change applied; tests GREEN
- **Estimated lines**: +25 / -5
- **Depends on**: 2.1

### Task 2.10 — Atomic `register_with_password/1`: Account + owner membership in one transaction

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/accounts.ex` (modify)
  - `meal_planner_api/test/meal_planner_api/accounts_registration_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: `register_with_password/1` MUST create the Account, the User, and the `:owner :active` membership atomically. If any step fails the entire registration rolls back (no orphan Account, no orphan User). Migration of pre-Phase-A users is separate (handled in 1.4) — this task only governs the **forward** registration path.
- **Acceptance criteria**:
  - [ ] test asserts successful registration yields exactly one `:owner :active` membership (RED)
  - [ ] test asserts a forced failure (e.g. duplicate email) rolls back the Account row
  - [ ] change applied; tests GREEN
- **Estimated lines**: +30 / -5
- **Depends on**: 1.5, 1.6

### Task 2.11 — Rewrite `Subscriptions.policy_for_account/1` to read `Account.plan`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/subscriptions.ex` (modify)
  - `meal_planner_api/test/meal_planner_api/subscriptions_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `policy_for_account(account)` reads `account.plan` and resolves through the `subscription_plans` table by `name` (decision Q3 / 5.3). Replaces the legacy `account_type`-based lookup. Caps from the `subscription_plans` row, not hard-coded.
- **Acceptance criteria**:
  - [ ] test asserts `:family_6` policy has `max_users: 6` (RED — current code reads `:group` and returns 5)
  - [ ] test asserts `:trial` policy has `max_users: 6`
  - [ ] test asserts missing `subscription_plans` row for an unknown plan returns an error tuple
  - [ ] change applied; tests GREEN
- **Estimated lines**: +30 / -10
- **Depends on**: 1.2, 1.6

### Task 2.12 — `account_repo.ex`: filter by `membership.account_id` instead of `user.account_id`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/data/account_repo.ex` (modify)
  - `meal_planner_api/test/meal_planner_api/data/account_repo_test.exs` (extend or new)
- **Type**: test-first (red→green)
- **Description**: All queries that filter `users.account_id = X` switch to preloading `memberships` for `:active` rows and filtering `memberships.account_id = X` (joined or sub-select). Add `list_active_memberships_for_account/1` helper used by PR 3 controllers.
- **Acceptance criteria**:
  - [ ] test asserts a User with two memberships (one in `Account_A`, one in `Account_B`) does not appear when querying `Account_B`-only resources via `user.account_id` path (RED)
  - [ ] change applied; test GREEN
  - [ ] test asserts the new `list_active_memberships_for_account/1` returns the right shape
- **Estimated lines**: +40 / -10
- **Depends on**: 1.5, 1.7

### Task 2.13 — `planning_repo.ex`: filter by `membership.account_id`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/data/planning_repo.ex` (modify)
  - `meal_planner_api/test/meal_planner_api/data/planning_repo_test.exs` (extend or new)
- **Type**: test-first (red→green)
- **Description**: Same swap as 2.12. Specifically: `schedule_meal/1`, `monthly_overview/2`, `get_planning_period/2`, and any other functions that filter by `account_id`. Add a property test (`StreamData`) covering multi-familia scenarios (proposal §"Risks").
- **Acceptance criteria**:
  - [ ] test asserts multi-familia User cannot read planning data of an Account they aren't an `:active` member of (RED)
  - [ ] change applied; test GREEN
- **Estimated lines**: +35 / -10
- **Depends on**: 2.12

### Task 2.14 — `inventory_repo.ex`: filter by `membership.account_id`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/data/inventory_repo.ex` (modify)
  - `meal_planner_api/test/meal_planner_api/data/inventory_repo_test.exs` (extend or new)
- **Type**: test-first (red→green)
- **Description**: Same swap as 2.12.
- **Acceptance criteria**:
  - [ ] test asserts cross-Account inventory read is filtered out (RED)
  - [ ] change applied; test GREEN
- **Estimated lines**: +25 / -8
- **Depends on**: 2.12

### Task 2.15 — `shopping_repo.ex`: filter by `membership.account_id`

- **Files**:
  - `meal_planner_api/lib/meal_planner_api/data/shopping_repo.ex` (modify)
  - `meal_planner_api/test/meal_planner_api/data/shopping_repo_test.exs` (extend or new)
- **Type**: test-first (red→green)
- **Description**: Same swap as 2.12.
- **Acceptance criteria**:
  - [ ] test asserts cross-Account shopping list read is filtered out (RED)
  - [ ] change applied; test GREEN
- **Estimated lines**: +25 / -8
- **Depends on**: 2.12

### Task 2.16 — `AccountsMembership` integration test (cross-vista)

- **Files**:
  - `meal_planner_api/test/meal_planner_api/accounts_membership_integration_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: End-to-end (in-process, no HTTP): seed two Accounts, two Users, full membership graph; exercise invite → accept → list → switch → leave. Asserts the entire Phase A use case chain (minus controllers) succeeds and respects invariants.
- **Acceptance criteria**:
  - [ ] test exercises invite → accept (existing User) → list → remove → leave flow
  - [ ] test exercises switch-account for a multi-familia User and asserts the claim map updates
  - [ ] test asserts concurrent invites on a full `:family_4` Account never produce >4 `:active + :invited` rows (race test using `Task.async_stream`)
- **Estimated lines**: +90 / -0
- **Depends on**: 2.1–2.8

**PR 2 subtotal**: +750 added, -56 modified, 16 tasks
**PR 2 review budget risk**: **High** (~694 net diff vs. 400-line budget — exceeds by ~290). The orchestrator should consider a sub-split (context-only vs. query rewrites) at apply time if maintainers push back; the natural sub-PR boundary is **PR 2a** (tasks 2.1–2.8, 2.11, 2.16 — context + service + tests) and **PR 2b** (tasks 2.9, 2.10, 2.12–2.15 — repos + auth wiring).

---

## PR 3 — Controllers + channels + services sweep + tests + docs

**Goal**: ship the Web layer. New controllers (`MembershipController`, `InviteController`, `AccountLifecycleController`), `auth_controller.ex` rewrite to mint `access_v2`, channel sweep (4 existing channels), controller tests, channel tests, `ARCHITECTURE.md` Auth Flow update, `FRONTEND_INTEGRATION.md` update.
**Env var at deploy**: `MEAL_PLANNER_TENANCY_V2=false` (kept off at deploy time, **flipped to `true`** as a separate operation after deploy completes — no DB migration, no app release required for the cutover).
**Forecast**: ~600 LOC (High risk).

### Task 3.1 — `MembershipController` index action ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/membership_controller.ex` (new)
  - `meal_planner_api/test/meal_planner_api_web/controllers/membership_controller_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: `GET /api/accounts/:account_id/memberships` → `MembershipController.index/2`. Pipes through `:auth, :enforce_account_scope`. Calls `AccountsMembership.list_memberships/1`. Returns `200` with `{memberships: [...]}` ordered `role ASC, joined_at ASC`. Returns `404 account_not_found` for non-members (no existence leak).
- **Acceptance criteria**:
  - [x] test asserts a `:member` of `Account_A` listing `Account_A`'s roster sees all rows (RED)
  - [x] test asserts a non-member of `Account_A` listing `Account_A` returns `404 account_not_found`
  - [x] test asserts cross-Account URL/JWT mismatch returns `403 account_mismatch`
  - [x] controller written; tests GREEN
- **Estimated lines**: +35 / -0
- **Depends on**: 2.5
- **Landed**: `a2da4c3`

### Task 3.2 — `MembershipController` delete action ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/membership_controller.ex` (extend)
  - `meal_planner_api/test/meal_planner_api_web/controllers/membership_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `DELETE /api/accounts/:account_id/memberships/:user_id` → `MembershipController.delete/2`. Owner-only. Hard-deletes the membership (Q3). Returns `204`. Errors: `:not_owner`, `:cannot_remove_owner`, `:membership_not_found`.
- **Acceptance criteria**:
  - [x] test asserts owner removes a `:member` and the row is gone (RED)
  - [x] test asserts owner cannot remove themselves
  - [x] test asserts non-owner actor returns `403 not_owner`
  - [x] controller extended; tests GREEN
- **Estimated lines**: +25 / -0
- **Depends on**: 3.1, 2.5
- **Landed**: `7ee21f1`

### Task 3.3 — `InviteController` create action (owner invites) ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/invite_controller.ex` (new)
  - `meal_planner_api/test/meal_planner_api_web/controllers/invite_controller_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: `POST /api/accounts/:account_id/invites` body `{email}`. Calls `AccountsMembership.invite/3`. Returns `201` with `{invite: {token, expires_at, membership_id, email}}`. Errors per spec `invite-and-accept.md` §6.1.
- **Acceptance criteria**:
  - [x] test asserts owner invite returns `201` with a plaintext token (RED)
  - [x] test asserts non-owner invite returns `403 not_owner`
  - [x] test asserts fifth invite on `:family_4` returns `409 seat_cap_reached`
  - [x] controller written; tests GREEN
- **Estimated lines**: +30 / -0
- **Depends on**: 2.3, 2.6
- **Landed**: `c3b6e4e`

### Task 3.4 — `InviteController` accept action (invitee accepts) ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/invite_controller.ex` (extend)
  - `meal_planner_api/test/meal_planner_api_web/controllers/invite_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `POST /api/invites/:token/accept` body `{}` (existing User) or `{name, password}` (new User). Calls `AccountsMembership.accept_invite/2`. Returns full auth payload (`access_token`, `refresh_token`, `user`, `account`, `membership`, `subscription`, `websocket`). Errors: `410 invite_token_used`, `410 invite_token_expired`, `409 already_a_member`.
- **Acceptance criteria**:
  - [x] test asserts existing User acceptance returns a fresh auth payload (RED)
  - [x] test asserts new User acceptance creates the User
  - [x] test asserts replay returns `410 invite_token_used`
  - [x] test asserts expired token returns `410 invite_token_expired`
  - [x] controller extended; tests GREEN
- **Estimated lines**: +50 / -0
- **Depends on**: 3.3, 2.4
- **Landed**: `99c2c72`

### Task 3.5 — `AccountLifecycleController` switch-account action ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/account_lifecycle_controller.ex` (new)
  - `meal_planner_api/test/meal_planner_api_web/controllers/account_lifecycle_controller_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: `POST /api/auth/switch-account` body `{membership_id}`. Calls `AccountsMembership.switch_account/2`. Returns `200` with the new auth payload. Errors: `403 not_your_membership`, `409 membership_not_active`, `404 membership_not_found`.
- **Acceptance criteria**:
  - [x] test asserts multi-familia User can switch Accounts (RED)
  - [x] test asserts switch to another User's membership returns `403 not_your_membership`
  - [x] test asserts switch to `:suspended` returns `409 membership_not_active`
  - [x] controller written; tests GREEN
- **Estimated lines**: +30 / -0
- **Depends on**: 2.8
- **Landed**: `7f5c0cf`

### Task 3.6 — `AccountLifecycleController` leave action ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/account_lifecycle_controller.ex` (extend)
  - `meal_planner_api/test/meal_planner_api_web/controllers/account_lifecycle_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `POST /api/accounts/:account_id/leave`. Calls `AccountsMembership.leave/2`. Returns `204`. Errors: `403 cannot_leave_owned_account`, `404 not_a_member`.
- **Acceptance criteria**:
  - [x] test asserts a `:member` leaving returns `204` (RED)
  - [x] test asserts the `:owner` leaving returns `403 cannot_leave_owned_account`
  - [x] controller extended; tests GREEN
- **Estimated lines**: +25 / -0
- **Depends on**: 2.5
- **Landed**: `37d5ee2`

### Task 3.7 — Router additions + `EnforceAccountScope` plug ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/router.ex` (modify)
  - `meal_planner_api/lib/meal_planner_api_web/plugs/enforce_account_scope.ex` (new)
  - `meal_planner_api/test/meal_planner_api_web/router_test.exs` (new)
  - `meal_planner_api/test/meal_planner_api_web/plugs/enforce_account_scope_test.exs` (new)
- **Type**: test-first (red→green)
- **Description**: `EnforceAccountScope` plug — for `:account_id`-bearing routes, compare `conn.path_params["account_id"]` against `conn.assigns.current_membership.account_id`. Halt with `403 account_mismatch` on mismatch. Add 6 routes per design §5.2: `POST /api/accounts/:account_id/invites`, `POST /api/invites/:token/accept`, `GET /api/accounts/:account_id/memberships`, `DELETE /api/accounts/:account_id/memberships/:user_id`, `POST /api/auth/switch-account`, `POST /api/accounts/:account_id/leave`. All under `pipe_through [:auth, :enforce_account_scope]` (except `/api/auth/switch-account` which has no `:account_id` in the URL — uses only `:auth`).
- **Acceptance criteria**:
  - [x] test asserts URL/JWT mismatch returns `403 account_mismatch` (RED)
  - [x] test asserts URL/JWT match proceeds to the controller
  - [x] test asserts all 6 routes resolve (200/201/204)
  - [x] router + plug written; tests GREEN
- **Estimated lines**: +55 / -10
- **Depends on**: 1.11, 3.1–3.6
- **Landed**: `20110bf`

### Task 3.8 — `auth_controller.ex` rewrite to mint `access_v2` when flag is on ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/auth_controller.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/controllers/auth_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: `password/2`, `register/2`, `refresh/2` consult `MEAL_PLANNER_TENANCY_V2`. When on → mint `access_v2` via `AccountsMembership.claims_for/2`; when off → keep `access` (existing). `refresh/2` preserves the original `typ` (no silent re-scoping). The `issue_auth_response/4` helper now takes a `typ: "access" | "access_v2"` arg.
- **Acceptance criteria**:
  - [x] test asserts register/login mints `access_v2` when flag is on (RED)
  - [x] test asserts refresh preserves `typ` from the incoming refresh token (RED)
  - [x] test asserts flag off mints `access_v1` (regression)
  - [x] controller updated; tests GREEN
- **Estimated lines**: +50 / -15
- **Landed**: `8765deb` (prerequisite: `register_with_password/1` exposes `membership`), `a9ddcbd` (this task)
- **Depends on**: 2.1, 2.9

### Task 3.9 — Channel sweep: `CalendarChannel.join/3` + `handle_in` membership check

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/channels/calendar_channel.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/channels/calendar_channel_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Per design §7 — `join("calendar:" <> topic_account_id, _payload, socket)` reads `LoadCurrentMembership.membership_from_socket/1`. Rejects with `{:error, %{reason: "forbidden"}}` when membership is `nil`, `account_id` mismatches the topic, or `status != :active`. Assigns `current_membership` to the socket. `handle_in` callbacks read `current_membership.account_id` (mechanical change).
- **Acceptance criteria**:
  - [x] test asserts cross-Account join rejected (RED)
  - [x] test asserts `:invited` membership join rejected
  - [x] test asserts `access_v1` legacy fallback accepted
  - [x] test asserts `handle_in` payload using a `meal_id` from another Account is rejected
  - [x] channel updated; tests GREEN
- **Estimated lines**: +45 / -10
- **Depends on**: 1.10, 1.12
- **Landed**: PR 3b task 3.9 (see `apply-progress.md` §"PR 3b").

### Task 3.10 — Channel sweep: `PlanningChannel.join/3` + `handle_in` membership check

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/channels/planning_channel.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/channels/planning_channel_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Same pattern as 3.9, prefix `"planning:"`.
- **Acceptance criteria**: identical to 3.9, scoped to `planning` prefix.
  - [x] test asserts cross-Account join rejected (RED)
  - [x] test asserts `:invited` membership join rejected
  - [x] test asserts `access_v1` legacy fallback accepted
  - [x] channel updated; tests GREEN
- **Estimated lines**: +45 / -10
- **Depends on**: 1.10, 1.12
- **Landed**: PR 3b task 3.10 (see `apply-progress.md` §"PR 3b").

### Task 3.11 — Channel sweep: `CookingChannel.join/3` + `handle_in` membership check

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/channels/cooking_channel.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/channels/cooking_channel_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Same pattern as 3.9, prefix `"cooking:"`. The `handle_in("set_is_cooked", payload, socket)` test is the canonical cross-Account mutation case from spec `membership-scoped-channels` §"handle_in with cross-Account entity id".
- **Acceptance criteria**:
  - [x] test asserts cross-Account join rejected (RED)
  - [x] test asserts cross-Account `meal_id` in `set_is_cooked` rejected with `meal_not_in_account` (RED)
  - [x] channel updated; tests GREEN
- **Estimated lines**: +45 / -10
- **Depends on**: 1.10, 1.12
- **Deviation** (documented in `apply-progress.md` §"PR 3b"): `CookingChannel` has no `set_is_cooked` handler on disk (that event only exists on `CalendarChannel`). The equivalent cross-Account entity check was implemented on `handle_in("start_session", %{"scheduled_meal_id" => ...})`, which is CookingChannel's only meal-id-bearing event, replying `{:error, %{reason: "meal_not_in_account"}}` on mismatch — same reason string the spec mandates, adapted to the event that actually exists.
- **Landed**: PR 3b task 3.11 (see `apply-progress.md` §"PR 3b").

### Task 3.12 — Channel sweep: `AIChannel.join/3` + `handle_in` membership check

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/channels/ai_channel.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/channels/ai_channel_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Same pattern as 3.9, prefix `"ai:"`. Note: only `ai` exists in `lib/meal_planner_api_web/channels/` today — `shopping_channel.ex` and `inventory_channel.ex` are referenced in the proposal §"Approach" but do not yet exist on disk; they are NOT created in Phase A (flagged in Open Questions below).
- **Acceptance criteria**:
  - [x] test asserts cross-Account join rejected (RED)
  - [x] channel updated; tests GREEN
- **Estimated lines**: +40 / -8
- **Depends on**: 1.10, 1.12
- **Deviation** (documented in `apply-progress.md` §"PR 3b"): `AIChannel`'s actual topic is `ai_chat:<room_id>` (an opaque chat/session id), not `ai:<account_id>` as this task's prefix assumed — there is no account_id in the topic to cross-check. The join guard implemented enforces "current_membership is present and `:active`" (nil/invited rejected) rather than a topic-vs-membership account match, since no such match is structurally possible for this channel. The "cross-Account join rejected" criterion is satisfied via the `:invited`-membership-rejected test instead of a literal cross-account topic test.
- **Landed**: PR 3b task 3.12 (see `apply-progress.md` §"PR 3b").

### Task 3.13 — Multi-familia two-socket channel test (dedicated checkpoint)

- **Files**:
  - `meal_planner_api/test/meal_planner_api_web/channels/membership_scoped_channel_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: Per design §8.5 and spec `membership-scoped-channels` §"Multi-familia User joining two topics via two sockets" — opens two sockets, one scoped to `Account_A`, one to `Account_B`, both for the same User. Joins `"planning:<A>"` on the first and `"planning:<B>"` on the second. Asserts both joins succeed. Pushes a broadcast to `planning:<A>` and asserts only the A-socket receives it.
- **Acceptance criteria**:
  - [x] test passes GREEN
- **Estimated lines**: +50 / -0
- **Depends on**: 3.9–3.12
- **Landed**: PR 3b task 3.13 (see `apply-progress.md` §"PR 3b").

### Task 3.14 — Controller sweep: `CalendarController` reads `current_membership.account_id` ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/calendar_controller.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/controllers/calendar_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Mechanical change — replace every `current_user.account_id` with `current_membership.account_id`. Filters in `Calendar.monthly_overview/2` and friends now resolve via `membership.account_id`.
- **Acceptance criteria**:
  - [x] test asserts multi-familia User calling `GET /api/calendar` with JWT scoped to `Account_A` returns `Account_A` data only (RED)
  - [x] change applied; test GREEN
- **Estimated lines**: +15 / -10
- **Depends on**: 1.11, 2.13
- **Landed**: `bcd7697` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.15 — Controller sweep: `PlanningController` ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/planning_controller.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/controllers/planning_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Same as 3.14.
- **Estimated lines**: +15 / -10
- **Depends on**: 3.14
- **Landed**: `99781a4`, `884ee89` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.16 — Controller sweep: `CookingController` ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/cooking_controller.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/controllers/cooking_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Same as 3.14.
- **Estimated lines**: +15 / -10
- **Depends on**: 3.14
- **Landed**: `9071560` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.17 — Controller sweep: `ShoppingController` ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/shopping_controller.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/controllers/shopping_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Same as 3.14.
- **Estimated lines**: +15 / -10
- **Depends on**: 3.14
- **Landed**: `1e8617c` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.18 — Controller sweep: `InventoryController` ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/inventory_controller.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/controllers/inventory_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Same as 3.14.
- **Estimated lines**: +15 / -10
- **Depends on**: 3.14
- **Landed**: `ef7155a` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.19 — Controller sweep: `PlanningChatController` ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/planning_chat_controller.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/controllers/planning_chat_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Same as 3.14.
- **Estimated lines**: +15 / -10
- **Depends on**: 3.14
- **Landed**: `e5cbc43` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.20 — Controller sweep: `RevenuecatController` ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/revenuecat_controller.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/controllers/revenuecat_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Same as 3.14 (webhook controller reads the Account from the request, but ownership verification moves to `current_membership`).
- **Estimated lines**: +15 / -8
- **Depends on**: 3.14
- **Landed**: `fa71bf6` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.21 — Service sweep (12 services read `current_membership`) ✅

- **Files** (12 files, but each is a one-line mechanical change in most cases; consolidate per service file in a single commit if the diff per service stays under ~30 LOC):
  - `meal_planner_api/lib/meal_planner_api/services/account_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/budget_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/cooking_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/generation_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/inventory_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/planning_chat_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/planning_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/price_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/recipe_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/revenuecat_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/shopping_service.ex`
  - `meal_planner_api/lib/meal_planner_api/services/subscription_service.ex`
- **Type**: test-first (red→green) — one shared integration test, but the per-file diff stays small
- **Description**: Each service that today takes a `user` and reads `user.account_id` is updated to take `membership` (or preload `memberships` and read the active one) and read `membership.account_id`. Where the service signature doesn't need to change (it already receives `account_id` from the caller), no edit is required — verified by `grep` first. This is the lightest possible sweep; services that today receive `account_id` directly require no change. **The task is committed as a single commit only if the total diff is ≤ 200 LOC and tests stay green.** If the diff is larger, split into two sub-tasks (3.21a "services that take `user`" and 3.21b "services that already take `account_id` (verification only)") at apply time.
- **Acceptance criteria**:
  - [x] grep verification: every service that previously read `user.account_id` now reads `membership.account_id`
  - [x] grep verification: no service still imports `User` for tenancy purposes
  - [x] shared integration test (`test/meal_planner_api/services/tenancy_sweep_test.exs`) — seeds a multi-familia User, calls one method per affected service, asserts cross-Account data is filtered out
- **Estimated lines**: +80 / -40 (variable; depends on how many services actually take `user`)
- **Depends on**: 3.14
- **Deviation** (documented in `apply-progress.md` §"PR 3c"): the grep-first audit found NONE of the 12 services needed an internal signature rewrite. 5 (`account_service`, `generation_service`, `price_service`, `revenuecat_service`, `subscription_service`) already take `account_id` directly. The other 7 read `user.account_id` (directly or via `Identity.ensure_persistent_identity/1`) but are already correctly scoped by the controller-boundary fix from tasks 3.14–3.20 (`AccountScopeHelpers.scope_user_to_membership/2`), which corrects `user.account_id` to `current_membership.account_id` before the User struct ever reaches these services — the single point tenancy scope enters the domain layer. A prerequisite fix to `Identity.ensure_persistent_identity/1` was required (see below) so it can resolve real multi-membership Users at all.
- **Landed**: `0cfd2c3` (PR 3c — see `apply-progress.md` §"PR 3c"); prerequisite fix `7abb5ab`

### Task 3.22 — `AccountsController` membership-aware endpoints (extend the existing controller, do not duplicate) ✅

- **Files**:
  - `meal_planner_api/lib/meal_planner_api_web/controllers/accounts_controller.ex` (modify)
  - `meal_planner_api/test/meal_planner_api_web/controllers/accounts_controller_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: The existing `AccountsController` has tenant-facing endpoints (e.g. `GET /api/accounts/me`). Replace every `current_user.account_id` read with `current_membership.account_id`. (The new `MembershipController` handles the roster/remove — this task only updates the existing controller's reads.)
- **Acceptance criteria**:
  - [x] test asserts `GET /api/accounts/me` returns the `membership.account_id`, not `user.account_id` (RED)
  - [x] change applied; test GREEN
- **Estimated lines**: +15 / -8
- **Depends on**: 1.11
- **Landed**: `0d1d6ba` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.23 — Cross-Account isolation test (dedicated checkpoint) ✅

- **Files**:
  - `meal_planner_api/test/meal_planner_api_web/cross_account_isolation_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: Per design §8.5 — end-to-end HTTP test (no internal context calls). User has `:owner` membership in `Account_A` and `:member` in `Account_B`. Issues `access_v2` token scoped to `Account_A`. Calls `GET /api/accounts/<Account_B_id>/memberships` and asserts `403 account_mismatch`. Repeat for `GET /api/calendar`, `GET /api/planning`, `GET /api/cooking`, `GET /api/inventory`, `GET /api/shopping`, `POST /api/auth/switch-account` (succeeds), then re-issues token and asserts the prior URL returns the Account_B data.
- **Acceptance criteria**:
  - [x] test passes GREEN
- **Estimated lines**: +60 / -0
- **Depends on**: 3.1–3.22
- **Deviation** (documented in `apply-progress.md` §"PR 3c"): `GET /api/planning`, `GET /api/cooking`, `GET /api/shopping` don't exist literally in `router.ex`; the closest real GET routes are used (`/api/planning/weekly`, `/api/cooking/sessions/:session_id`, `/api/shopping-list`). Only `GET /api/accounts/:account_id/memberships` carries `:account_id` in its URL, so it's the only route that can produce `403 account_mismatch`; the other 5 routes carry no URL `:account_id` at all — their isolation guarantee is proven by asserting they return ONLY the correctly-scoped Account's data (never the other Account's), both before and after `switch-account`.
- **Landed**: `8a0f807` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.24 — Update `ARCHITECTURE.md` Auth Flow section ✅

- **Files**:
  - `meal_planner_api/ARCHITECTURE.md` (modify)
- **Type**: docs-only (no test)
- **Description**: Document the dual-token model (`access` vs `access_v2`), the `current_user` + `current_membership` dual-assign, the `LoadCurrentMembership` plug, the `EnforceAccountScope` plug, and the env-var cutover. Add a sequence diagram for invite → accept → switch.
- **Acceptance criteria**:
  - [x] Auth Flow section lists both token types with their claim shapes
  - [x] Pipeline diagram includes `LoadCurrentMembership` and `EnforceAccountScope`
  - [x] Cutover procedure (env var flip) is documented
- **Estimated lines**: +50 / -10
- **Depends on**: 1.11, 3.7, 3.8
- **Landed**: `5ddeafc` (PR 3c — see `apply-progress.md` §"PR 3c")

### Task 3.25 — Update `meal_planner_api/docs/FRONTEND_INTEGRATION.md` ✅

- **Files**:
  - `meal_planner_api/docs/FRONTEND_INTEGRATION.md` (modify)
- **Type**: docs-only (no test)
- **Description**: Document the new JWT claim shape (`access_v2`), the 6 new endpoints (invites, accept, list memberships, remove member, switch-account, leave), and the multi-familia two-socket pattern for the React Native client. Include request/response examples for every endpoint with the error shapes from spec `invite-and-accept.md` and `multi-familia-switch-account.md`.
- **Acceptance criteria**:
  - [x] `access_v2` claim shape is documented with an example JWT
  - [x] All 6 new endpoints are documented with request, response, error shapes
  - [x] Multi-familia two-socket pattern is explained
- **Estimated lines**: +80 / -5
- **Depends on**: 3.1–3.8
- **Landed**: `e293141` (PR 3c — see `apply-progress.md` §"PR 3c")

**PR 3 subtotal**: +960 added, -219 modified, 25 tasks
**PR 3 review budget risk**: **High** (~741 net diff vs. 400-line budget — exceeds by ~340). Mitigation: every per-controller / per-channel / per-service task is its own commit, so a reviewer can scan one at a time. If maintainers push back, the orchestrator may split PR 3 into 3a (controllers 3.1–3.7 + auth rewrite 3.8) and 3b (channels 3.9–3.13 + sweeps 3.14–3.22 + tests + docs 3.23–3.25) at apply time.

---

## Task Count Summary

| PR | Tasks | LOC (est.) | Files touched | Risk |
|----|-------|-----------|---------------|------|
| 1 | 14 | +660 / -32 | 4 migrations + 6 schemas/plugs + 6 tests | Medium |
| 2 | 16 | +750 / -56 | 1 context + 1 service + 4 repo rewrites + 1 controller sweep + 8 tests | High |
| 3 | 25 | +960 / -219 | 3 new controllers + 4 channel sweeps + 12 service sweep + 7 controller sweep + 1 auth rewrite + 1 plug + 2 docs + 12 tests | High |
| **Total** | **55** | **+2,370 / -307 (~2,677 net diff)** | **~70 files** | **High overall (chained PRs required)** |

(Note: the net diff includes substantial test code — production code is closer to the proposal's ~1,500 forecast.)

---

## Open questions for `sdd-apply`

These need resolution (or explicit deferral) before or during `sdd-apply`. None are blockers; the orchestrator can resolve them inline.

1. **Channel count discrepancy** — the proposal and design reference 6 channels (`planning`, `cooking`, `calendar`, `shopping`, `inventory`, `ai_channel`), but only 4 exist on disk today (`planning`, `cooking`, `calendar`, `ai`). PR 3 tasks 3.9–3.12 cover the 4 existing channels only. Decision needed: (a) create `shopping_channel.ex` and `inventory_channel.ex` in a separate change; (b) defer until those channels are needed; (c) include them in PR 3 as additional tasks.
2. **PR 2 split** — at ~694 net LOC, PR 2 is over the 400-line budget. The natural sub-PR boundary (PR 2a = tasks 2.1–2.8, 2.11, 2.16; PR 2b = tasks 2.9, 2.10, 2.12–2.15) is documented in PR 2's subtotal. Decision needed at apply time.
3. **PR 3 split** — at ~741 net LOC, PR 3 is also over. The natural sub-PR boundary (PR 3a = controllers + auth; PR 3b = channels + sweeps + tests + docs) is documented in PR 3's subtotal. Decision needed at apply time.
4. **Chain strategy confirmation** — proposal §"Approach" chose "feature branch chain"; the orchestrator's preflight cached `ask-always`. The orchestrator should ask at `sdd-apply` time before slicing PR 1.
5. **Invite token entropy** (Q7) — 32 bytes URL-safe base64 = ~43 chars. Confirmed in design §10 (Q7). No action.
6. **`access_v1` deprecation policy** (Q5) — design §4.4 says the follow-up change `tenancy-v2-hardening` ships after the React Native app consumes `current_membership`. No Phase A action.
7. **Factory macro for multi-familia in tests** (Q6) — `user_with_memberships/2` covers it. No additional factory needed.
8. **`subscription_plan` FK enforcement** — design §2.6 says `accounts.subscription_plan_id` becomes NOT NULL and FK-enforced to `subscription_plans` for all four plans. The current migration may not have that FK in place — verify in PR 1 task 1.2. If not, add a follow-up migration in PR 1 or a separate task.
9. **`users.role` field removal** — design keeps `:role` on `User` for the dual-write window but proposal §Stream A says "drop `users.role`". Decide in PR 1 task 1.7 whether to drop the column in migration 1.3 (preferred — keeps the schema clean) or keep it nullable for one more PR. **Recommendation: drop in 1.3** to avoid the dual-write trap.
10. **`ARCHITECTURE.md` and `FRONTEND_INTEGRATION.md` doc reviews** — both tasks (3.24, 3.25) are docs-only and follow the standard doc review path. No additional subagent needed.

---

## Verification (per phase, per design §9.2)

| PR | Command sequence | Pass criteria |
|---|---|---|
| 1 | `mix ecto.drop && mix ecto.create && mix ecto.migrate && mix test test/support/migration_sanity_test.exs && mix test test/support/migration_shape_test.exs && mix precommit` | All four migrations apply; rollback + re-migrate is idempotent; `check_account_membership_invariants()` returns no violations; `mix precommit` clean |
| 2 | `mix precommit` | All new context + service tests GREEN; existing controller tests still GREEN (pipeline synthesizes `current_membership` from `current_user.account_id`); `mix dialyzer` (if configured) clean |
| 3 | `mix precommit` | All new controller + channel + cross-account tests GREEN; manual smoke test of invite → accept → switch → leave → cross-Account join rejection (per design §9.3); `mix dialyzer` (if configured) clean |

---

## References

- **Proposal**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/proposal.md`
- **Design**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/design.md`
- **Specs (6, in canonical order)**:
  1. `…/specs/account-membership.md`
  2. `…/specs/auth-pipeline-and-current-resource.md`
  3. `…/specs/guardian-jwt-claims.md`
  4. `…/specs/invite-and-accept.md`
  5. `…/specs/membership-scoped-channels.md`
  6. `…/specs/multi-familia-switch-account.md`
- **PRD**: [vicenzogiordana/myfood#1](https://github.com/vicenzogiordana/myfood/issues/1) — Phase A.
- **Project CONTEXT**: `/Users/vicenzogiordana/Desktop/Progra/myfood/context.md` §3 (Monetization plans), §4 (Account / User / AccountMembership schema), §4b (deletion semantics — informs what we do **not** ship in Phase A).
- **API architecture**: `/Users/vicenzogiordana/Desktop/Progra/myfood/meal_planner_api/ARCHITECTURE.md` — Clean Architecture boundaries; Auth Flow section to be updated in PR 3.
- **API OpenSpec config**: `/Users/vicenzogiordana/Desktop/Progra/myfood/meal_planner_api/openspec/config.yaml` — `strict_tdd: true`, `max_changed_lines: 400`, `chained_pr_recommended_above: 400`.
- **API sub-project conventions**: `/Users/vicenzogiordana/Desktop/Progra/myfood/meal_planner_api/AGENTS.md` — Phoenix v1.8 conventions, `mix precommit` for verification, Req for HTTP, `start_supervised!/1` for test processes.
- **Existing module patterns inspected**:
  - `meal_planner_api/lib/meal_planner_api/persistence/accounts.ex`,
  - `…/persistence/accounts/account.ex`,
  - `…/persistence/accounts/user.ex`,
  - `meal_planner_api/lib/meal_planner_api_web/auth_pipeline.ex`,
  - `…/user_socket.ex`,
  - `…/channels/{calendar,planning,cooking,ai}_channel.ex`,
  - `…/controllers/{auth,accounts,calendar,planning,cooking,shopping,inventory,planning_chat,revenuecat}_controller.ex`,
  - `meal_planner_api/priv/repo/migrations/20260322090000_create_accounts_and_users.exs`,
  - `meal_planner_api/priv/repo/migrations/20260326120000_create_subscription_plans.exs`.
- **Tone reference**: `meal_planner_api/openspec/artifacts/v2-planning-tasks.md`.

---

## Next Step

Ready for `sdd-apply` (with PR 1 as the first slice). The orchestrator should:

1. Confirm the chain strategy (`ask-always` per preflight C1) — propose **feature-branch-chain** with PR 1 → `main`, PR 2 → PR 1 branch, PR 3 → PR 2 branch.
2. Resolve the open questions in §"Open questions for sdd-apply" before launching apply (especially #1 channel count and #9 `users.role` drop).
3. Consider the PR 2 / PR 3 sub-splits if maintainers prefer more granular PRs.
4. Set the env var to `MEAL_PLANNER_TENANCY_V2=false` for PR 1 deploy, unchanged through PR 2 deploy, then **flip to `true` as a separate operation** after PR 3 deploy (per design §9.1).