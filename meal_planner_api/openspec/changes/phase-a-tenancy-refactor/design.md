# Design: Phase A — Tenancy Refactor (User → AccountMembership)

> **Change**: `phase-a-tenancy-refactor`
> **Owner sub-project**: `meal_planner_api`
> **Status**: `design` (proposal + 6 specs approved; design ready for `sdd-tasks`)
> **PRD**: [vicenzogiordana/myfood#1](https://github.com/vicenzogiordana/myfood/issues/1) — Phase A.
> **Upstream artifacts**: [`proposal.md`](proposal.md), [`specs/`](specs/).
> **Review budget**: 400 changed lines per PR → 3 chained PRs (~400 / ~500 / ~600 LOC).
> **Architecture invariants**: Clean Architecture boundaries (`Web` thin, `Application` owns use cases, `Persistence` owns queries — `meal_planner_api/ARCHITECTURE.md`). Both sub-projects must follow `meal_planner_api/AGENTS.md` (Elixir / Phoenix v1.8 conventions, Guardian for JWT, `mix precommit` for verification).

## 1. Architecture Overview

Phase A replaces the single-tenant `User.account_id` join with the canonical
multi-tenant `AccountMembership` join entity, without breaking the deployed
React Native client. The cutover is governed by a JWT `typ` claim: `"access_v1"`
(legacy, `user.account_id` resolves tenancy) and `"access_v2"` (new,
`membership.account_id` resolves tenancy). `AuthPipeline` accepts both during
the cutover window and always assigns **both** `current_user` and
`current_membership` to the `conn`/socket — controllers and channels read
`current_membership` so the same code path serves both token types via a
virtual-membership fallback when the claim is absent. Three chained PRs
land the work behind the flag: PR 1 ships the data model + dual-write Guardian,
PR 2 ships the use-case layer (`AccountsMembership` context, `InviteService`,
`Subscriptions` rewrite), PR 3 ships the controllers, channels, factory
extensions, and `ARCHITECTURE.md` doc updates. The feature-flag env var
(`MEAL_PLANNER_TENANCY_V2`) is the only cutover step; no DB migration, no
forced logout, no mobile release required.

The architecture respects the Clean Architecture boundary: `Web` (controllers,
channels, pipeline) stays thin and only translates HTTP/WS → context calls;
`Application` (`MealPlannerApi.AccountsMembership`, `InviteService`,
`Subscriptions`) owns the use cases; `Persistence`
(`AccountMembership` schema, updated `Account`/`User`) owns Ecto schemas and
queries. No controller reads `User.account_id` directly — it goes through
`current_membership.account_id` — and no schema embeds tenancy logic.

## 2. Data Model

### 2.1 New table: `account_memberships`

DDL (PR 1, migration `2026XXXX_create_account_memberships.exs`):

```elixir
create table(:account_memberships, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
  add :user_id,    references(:users,    type: :binary_id, on_delete: :delete_all), null: false
  add :role,    :string, null: false  # Ecto.Enum :owner | :member
  add :status,  :string, null: false  # Ecto.Enum :active | :invited | :suspended
  add :invited_by_user_id,    references(:users, type: :binary_id, on_delete: :nilify_all)
  add :invite_token_hash,     :string        # nil after acceptance; opaque SHA-256
  add :invite_expires_at,     :utc_datetime_usec
  add :joined_at,             :utc_datetime_usec  # set when :invited → :active

  timestamps(type: :utc_datetime_usec)
end

# Q3 — status enum: 3 values, hard-delete on leave/remove.
create constraint(:account_memberships, :account_memberships_role_check,
         check: "role IN ('owner', 'member')")
create constraint(:account_memberships, :account_memberships_status_check,
         check: "status IN ('active', 'invited', 'suspended')")

# Q9 — index naming aligned with project convention
# (existing migration `20260322090000_create_accounts_and_users.exs` uses
# `create index(:users, [:account_id])` style — Phoenix/Elixir default names).
create index(:account_memberships, [:user_id, :account_id], name: :account_memberships_user_id_account_id_index)
create index(:account_memberships, [:account_id, :status],  name: :account_memberships_account_id_status_index)
create index(:account_memberships, [:user_id, :status],     name: :account_memberships_user_id_status_index)

# Hard guarantee: at most one active membership per (account, user).
# (A suspended row can be re-invited — that is handled by the app layer
# overwriting invite_token_hash, NOT a second row.)
create unique_index(:account_memberships, [:account_id, :user_id],
         where: "status = 'active'",
         name: :account_memberships_active_account_user_unique_index)
```

Notes:
- `invite_token_hash` stores SHA-256 of the plaintext token; the plaintext is
  returned **once** in the invite response and never persisted.
- `invited_by_user_id` is `ON DELETE NILIFY` so cascade does not destroy
  audit trail when a User is deleted (full User deletion is B1 — out of scope
  for Phase A; we still must not lose the FK).
- The `account_memberships_active_account_user_unique_index` partial unique
  index is the canonical "exactly one active membership per (account, user)"
  invariant. `invited` rows are allowed to coexist with a `:suspended` row
  so the owner can re-invite a previously-suspended member without deleting
  the suspended row first.

### 2.2 Changes to `accounts` (PR 1)

```elixir
# Drop account_type, add plan enum
alter table(:accounts) do
  remove :account_type
  add :plan, :string, null: false, default: "individual"
end

create constraint(:accounts, :accounts_plan_check,
         check: "plan IN ('individual', 'family_4', 'family_6', 'trial')")

# Drop the legacy has_many :users; replaced by membership join
# (handled in schema, not migration.)
```

### 2.3 Changes to `users` (PR 1)

```elixir
# Decision 5.1 — nullable for the dual-write window; drop in a later migration.
alter table(:users) do
  modify :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
         null: true
end
```

### 2.4 Backfill SQL (PR 1, migration `2026XXXX_add_account_memberships_backfill.exs`)

```sql
-- Batch insert: for every existing (user, account) pair, materialize one
-- :active :owner membership. The default role for legacy users is :owner.
-- The migration runs in 1,000-row batches with a 50ms sleep between batches
-- to avoid holding a write lock on a populated DB (proposal §"Migration backfill").
DO $$
DECLARE
  batch_size int := 1000;
  inserted   int := 0;
BEGIN
  LOOP
    WITH batch AS (
      SELECT u.id AS user_id, u.account_id, u.role, u.inserted_at
      FROM users u
      WHERE u.account_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM account_memberships m
          WHERE m.user_id = u.id
            AND m.account_id = u.account_id
            AND m.status = 'active'
        )
      ORDER BY u.inserted_at
      LIMIT batch_size
      FOR UPDATE SKIP LOCKED
    )
    INSERT INTO account_memberships (id, account_id, user_id, role, status,
                                     invited_by_user_id, invite_token_hash,
                                     invite_expires_at, joined_at,
                                     inserted_at, updated_at)
    SELECT gen_random_uuid(),
           b.account_id,
           b.user_id,
           COALESCE(b.role, 'owner'),
           'active',
           NULL,
           NULL,
           NULL,
           b.inserted_at,
           now(), now()
    FROM batch b;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    EXIT WHEN inserted = 0;

    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;

-- Q2 — Invariant check invoked at end of migration transaction (see 2.5).
SELECT check_account_membership_invariants();
```

### 2.5 Reconciliation queries (Q2)

A PostgreSQL function `check_account_membership_invariants()` is created in
the backfill migration and invoked **inside the same transaction** before
commit. If any check fails, the migration rolls back and CI surfaces the error.

```sql
CREATE OR REPLACE FUNCTION check_account_membership_invariants()
RETURNS void AS $$
DECLARE
  missing_memberships bigint;
  orphan_accounts      bigint;
  multi_owner_accounts bigint;
BEGIN
  -- 1) Every legacy (user, account) pair in users.account_id has exactly one
  --    :active membership.
  SELECT COUNT(*) INTO missing_memberships
  FROM users u
  LEFT JOIN account_memberships m
    ON m.user_id = u.id AND m.account_id = u.account_id AND m.status = 'active'
  WHERE u.account_id IS NOT NULL AND m.id IS NULL;

  IF missing_memberships > 0 THEN
    RAISE EXCEPTION 'backfill_invariant_failed: % users have no active membership',
      missing_memberships;
  END IF;

  -- 2) Every legacy User.account_id row is accounted for (no orphans).
  SELECT COUNT(*) INTO orphan_accounts
  FROM users u
  WHERE u.account_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id = u.account_id);

  IF orphan_accounts > 0 THEN
    RAISE EXCEPTION 'backfill_invariant_failed: % users reference missing account',
      orphan_accounts;
  END IF;

  -- 3) Every Account has exactly one :owner :active membership.
  SELECT COUNT(*) INTO multi_owner_accounts
  FROM account_memberships
  WHERE role = 'owner' AND status = 'active'
  GROUP BY account_id
  HAVING COUNT(*) <> 1;

  IF multi_owner_accounts > 0 THEN
    RAISE EXCEPTION 'backfill_invariant_failed: % accounts do not have exactly 1 :owner',
      multi_owner_accounts;
  END IF;
END;
$$ LANGUAGE plpgsql;
```

### 2.6 `subscription_plans` seed (PR 1, in the same migration as `plan` enum)

```elixir
# Q10 — add :family_6 and :trial rows; :trial is reserved for the
# follow-up change that wires the trial-expiration timer. Existing rows for
# `:individual` and `:family_4` (from `20260326120000_create_subscription_plans.exs`)
# are kept and matched by name. `:group` from the legacy `account_type` is
# migrated to `:family_4` in the data-migration step above.

%{}
|> Enum.into([
  %{name: "family_6", max_users: 6, max_planning_days: 30,
    revenuecat_entitlement_id: "family_6"},
  %{name: "trial",    max_users: 6, max_planning_days: 30,
    revenuecat_entitlement_id: "trial"}
])
|> Enum.each(fn attrs ->
  %SubscriptionPlan{}
  |> SubscriptionPlan.changeset(attrs)
  |> Repo.insert!(on_conflict: :nothing, conflict_target: :name)
end)
```

Per spec (`account-membership.md` "Account.plan enum and subscription_plans
seed"), `accounts.subscription_plan_id` becomes NOT NULL and FK-enforced to
`subscription_plans` for all four plans.

## 3. JWT Claim Shape

The `typ` claim is the cutover switch. Q4 (resolved): `access_v2` **adds**
`membership_id`, `plan`, `role`, `status` to the existing claim set; `access_v1`
is unchanged from today. No silent re-scoping on refresh.

### 3.1 `access_v1` (legacy, `typ: "access"`)

```json
{
  "sub": "<user-id>",
  "typ": "access",
  "account_id": "<account-id>",
  "account_type": "individual | group",
  "subscription_tier": "<rc-tier>",
  "email": "<email>",
  "name": "<name>",
  "iat": 1719000000,
  "exp": 1719086400
}
```

### 3.2 `access_v2` (new, `typ: "access_v2"`)

```json
{
  "sub": "<user-id>",
  "typ": "access_v2",
  "membership_id": "<membership-uuid>",
  "account_id": "<account-uuid>",
  "role": "owner | member",
  "plan": "individual | family_4 | family_6 | trial",
  "status": "active | invited | suspended",
  "email": "<email>",
  "name": "<name>",
  "iat": 1719000000,
  "exp": 1719086400
}
```

`AccountsMembership.claims_for/2` (new, PR 2) builds this map by preloading
the active membership; the existing `Accounts.claims_for/2` keeps building the
`access_v1` map (no caller is changed in PR 2 — only the controller consults
the env var in PR 3 to pick which builder to call).

## 4. Dual-Write Strategy

### 4.1 Feature flag

```elixir
# config/runtime.exs (or config/config.exs loaded at boot)
config :meal_planner_api, :tenancy_v2_only,
  System.get_env("MEAL_PLANNER_TENANCY_V2", "false") == "true"
```

- `MEAL_PLANNER_TENANCY_V2=false` (default at PR 1 deploy) → `AuthController`
  mints `typ: "access"` via `Accounts.claims_for/2`. Behavior is identical
  to pre-Phase A.
- `MEAL_PLANNER_TENANCY_V2=true` → `AuthController` mints `typ: "access_v2"`
  via `AccountsMembership.claims_for/2`.
- `AuthPipeline.VerifyHeader` accepts **both** `typ` values during the
  cutover window. The flag affects issuance only.

### 4.2 Pipeline dispatch (Q8 — backward compat)

`AuthPipeline` runs after `Guardian.Plug.LoadResource` (which loads
`current_user`). A new custom plug
`MealPlannerApiWeb.Plugs.LoadCurrentMembership` (PR 1) populates
`conn.assigns.current_membership`:

- If `claims["typ"] == "access_v2"` → load the `AccountMembership` row by
  `claims["membership_id"]`. Missing/invalid → `401 membership_id_required`.
- If `claims["typ"] == "access"` (legacy fallback) → synthesize a virtual
  membership struct (Q1 — see §10) from `current_user.account_id` and
  `current_user.role` + the `Account.plan` lookup. **No row is inserted.**
  Controllers/channels read `current_membership` exactly as for `access_v2`.

A second custom plug `EnforceAccountScope` (PR 3) runs after
`LoadCurrentMembership` and rejects with `403 account_mismatch` if the URL
`:account_id` does not match `current_membership.account_id`.

### 4.3 Channel fallback

The same `LoadCurrentMembership` logic is invoked in `UserSocket.connect/3`
(PR 1). Each channel's `join/3` reads `socket.assigns.current_membership`
(Q8 — synthesized for legacy tokens, real row for `access_v2`).

### 4.4 Deprecation timeline (Q5)

- **PR 1 deploy** — `MEAL_PLANNER_TENANCY_V2=false`. Both `access_v1` and
  `access_v2` verify paths are live; only `access_v1` is issued.
- **Cutover** — operator flips env var to `true` (and restarts). New tokens
  are `access_v2`. Existing `access_v1` tokens keep verifying until TTL
  (15 min access / 7 day refresh).
- **Force-refresh window** — 7 days after the flip. Refresh tokens issued
  before the flip are still `access_v1`. After 7 days the oldest refresh
  tokens have all rotated to `access_v2`.
- **Follow-up change `tenancy-v2-hardening`** — refuses `access_v1` entirely
  after the React Native app ships a release that consumes `current_membership`
  from the auth payload. That change is **not** in Phase A scope.

## 5. Module Structure

### 5.1 New modules (paths absolute)

| File | Layer | Responsibility |
|---|---|---|
| `meal_planner_api/lib/meal_planner_api/persistence/accounts/account_membership.ex` | Persistence | `AccountMembership` schema, Ecto.Enum `role`/`, changeset (validate `role`, `status`, FK, `invite_token_hash`). |
| `meal_planner_api/lib/meal_planner_api/accounts_membership.ex` | Application | Public use-case API: `invite/3`, `accept_invite/2`, `list_memberships/1`, `remove_member/2`, `leave/1`, `switch_account/2`, `current_membership/1`, `seat_usage/1`, `enforce_seat_cap/2`, `claims_for/2`. |
| `meal_planner_api/lib/meal_planner_api/services/invite_service.ex` | Application | `mint_token/2` (32-byte URL-safe base64), `hash_token/1` (SHA-256), `verify_and_consume/1` (single-use, expiry). |
| `meal_planner_api/lib/meal_planner_api_web/controllers/membership_controller.ex` | Web | `index/2` (roster), `delete/2` (owner removes member). |
| `meal_planner_api/lib/meal_planner_api_web/controllers/invite_controller.ex` | Web | `create/2` (owner invites), `accept/2` (invitee accepts token). |
| `meal_planner_api/lib/meal_planner_api_web/controllers/account_lifecycle_controller.ex` | Web | `switch_account/2`, `leave/2`. |
| `meal_planner_api/lib/meal_planner_api_web/plugs/load_current_membership.ex` | Web | Populates `current_membership` from JWT claims; legacy `access_v1` fallback. |
| `meal_planner_api/lib/meal_planner_api_web/plugs/enforce_account_scope.ex` | Web | Rejects `403 account_mismatch` on URL `:account_id` ≠ `current_membership.account_id`. |

### 5.2 Modified modules

| File | Change |
|---|---|
| `meal_planner_api/lib/meal_planner_api/persistence/accounts/account.ex` | Drop `account_type` field, add `plan` `Ecto.Enum`; drop `has_many :users`; add `has_many :memberships`. |
| `meal_planner_api/lib/meal_planner_api/persistence/accounts/user.ex` | `account_id` nullable; add `has_many :memberships`; add `unique_constraint` already present for `:email`. |
| `meal_planner_api/lib/meal_planner_api/persistence/accounts.ex` | Keep persistence helpers; `get_user_with_memberships/1`, `list_memberships_for_account/1`, `ensure_owner_membership/2` (used by registration). |
| `meal_planner_api/lib/meal_planner_api/accounts.ex` | (PR 2) `register_with_password/1` creates Account + owner membership atomically; delegate tenancy ops to `AccountsMembership`. `claims_for/2` (legacy `access_v1`) preserved unchanged. |
| `meal_planner_api/lib/meal_planner_api/subscriptions.ex` | `policy_for_account/1` resolves through `Account.plan` → `subscription_plans` by `name` (Q3-aligned; replaces `account_type`-based lookup). |
| `meal_planner_api/lib/meal_planner_api_web/auth_pipeline.ex` | Add `LoadCurrentMembership` + `EnforceAccountScope` plugs. `VerifyHeader` continues to accept `access` (legacy); add `access_v2` to accepted types. |
| `meal_planner_api/lib/meal_planner_api_web/user_socket.ex` | `connect/3` populates both `current_user` and `current_membership` (via `LoadCurrentMembership.call_for_socket/2`). |
| `meal_planner_api/lib/meal_planner_api_web/controllers/auth_controller.ex` | `issue_auth_response/4` consults `tenancy_v2_only` flag (Q4) and mints `access_v2` when on; still mints `access_v1` when off. `refresh/2` re-issues with the **same** `typ` as the original token (no silent re-scoping). |
| `meal_planner_api/lib/meal_planner_api_web/router.ex` | Add `POST /api/accounts/:account_id/invites`, `POST /api/invites/:token/accept`, `GET /api/accounts/:account_id/memberships`, `DELETE /api/accounts/:account_id/memberships/:user_id`, `POST /api/auth/switch-account`, `POST /api/accounts/:account_id/leave`. |
| `meal_planner_api/lib/meal_planner_api_web/channels/{planning,cooking,calendar,shopping,inventory,ai}_channel.ex` | `join/3` reads `current_membership` and rejects when topic `account_id ≠ current_membership.account_id`. `handle_in` callbacks read `current_membership.account_id` instead of `current_user.account_id`. |
| `meal_planner_api/lib/meal_planner_api/data/{account_repo,planning_repo,inventory_repo,shopping_repo}.ex` | Queries that filter `users.account_id` switch to filtering `memberships.account_id` for `:active` memberships (preload + sub-select or JOIN). |
| `meal_planner_api/test/support/factory.ex` (or `factory_helpers.ex`) | New factory macros (Q6 — see §8). |
| `meal_planner_api/ARCHITECTURE.md` | Auth Flow section updated with dual-token model and `current_membership` semantics. |

## 6. API Contract

All endpoints under `pipe_through [:auth, :enforce_account_scope]` (the
custom plug enforces URL ↔ JWT `account_id` match).

### 6.1 `POST /api/accounts/:account_id/invites`

- **Roles**: `:owner` only.
- **Body**: `{ "email": "ana@example.com" }`.
- **Response 201**: `{ "invite": { "token": "<plaintext>", "expires_at": "...", "membership_id": "<uuid>", "email": "ana@example.com" } }`.
- **Errors**: `403 not_owner` | `404 account_not_found` | `409 seat_cap_reached` | `409 already_invited`.
- **Side effects**: inserts `:invited` row with `invite_token_hash`, `invite_expires_at = now + 7 days`, `invited_by_user_id = current_user.id`. Seat-cap check inside `SELECT … FOR UPDATE` on the Account row (proposal §"Risks").

### 6.2 `POST /api/invites/:token/accept`

- **Roles**: any authenticated User (or new User via password payload).
- **Body**: `{}` (existing User) **or** `{ "name": "...", "password": "..." }` (new User).
- **Response 200**: full auth payload — `{ "access_token", "refresh_token", "user", "account", "membership", "subscription", "websocket": {...} }`.
- **Errors**: `401 unauthorized` | `410 invite_token_used` | `410 invite_token_expired` | `409 already_a_member`.

### 6.3 `GET /api/accounts/:account_id/memberships`

- **Roles**: any `:active` member of the Account.
- **Response 200**: `{ "memberships": [ { "user_id", "email", "name", "role", "status", "joined_at" }, ... ] }`, ordered `role ASC, joined_at ASC` (owner first).
- **Errors**: `404 account_not_found` (no existence leak) | `403 not_a_member`.

### 6.4 `DELETE /api/accounts/:account_id/memberships/:user_id`

- **Roles**: `:owner` only.
- **Response 204**: empty.
- **Errors**: `403 not_owner` | `403 cannot_remove_owner` | `404 membership_not_found`.
- **Side effects**: hard-delete the row (Q3). Re-invitation later re-checks the seat cap.

### 6.5 `POST /api/auth/switch-account`

- **Auth**: any `:active` Bearer token.
- **Body**: `{ "membership_id": "<uuid>" }`.
- **Response 200**: full auth payload with new `access_token` / `refresh_token` and the serialized membership.
- **Errors**: `403 not_your_membership` | `409 membership_not_active` | `404 membership_not_found`.

### 6.6 `POST /api/accounts/:account_id/leave`

- **Roles**: any `:active` `:member` (NOT `:owner`).
- **Response 204**.
- **Errors**: `403 cannot_leave_owned_account` (Q3 — owner returns this) | `404 not_a_member`.

## 7. Channel Join Pattern

The pattern repeats across all six channels. Q8 (resolved): prefer
`current_membership`; fall back to legacy `current_user.account_id` only
when the JWT is `access_v1`. Below is `CalendarChannel.join/3`; the same
guard applies to `planning`, `cooking`, `shopping`, `inventory`, `ai_channel`.

```elixir
defmodule MealPlannerApiWeb.CalendarChannel do
  use MealPlannerApiWeb, :channel

  alias MealPlannerApiWeb.Plugs.LoadCurrentMembership

  @impl true
  def join("calendar:" <> topic_account_id, _payload, socket) do
    membership =
      LoadCurrentMembership.membership_from_socket(socket)

    cond do
      is_nil(membership) ->
        {:error, %{reason: "forbidden"}}

      membership.account_id != topic_account_id ->
        {:error, %{reason: "forbidden"}}

      membership.status != :active ->
        {:error, %{reason: "forbidden"}}

      true ->
        {:ok,
         socket
         |> assign(:account_id, topic_account_id)
         |> assign(:current_membership, membership)}
    end
  end

  # handle_in callbacks read current_membership.account_id instead of
  # current_user.account_id (mechanical change per spec
  # `auth-pipeline-and-current-resource` §"Controllers read membership.account_id").
end
```

The same `join/3` shape (with a different channel prefix) is applied to
`PlanningChannel`, `CookingChannel`, `ShoppingChannel`, `InventoryChannel`,
and `AIChannel`. `handle_in` callbacks always read
`socket.assigns.current_membership.account_id` (Q8 fallback handles legacy).

## 8. Testing Strategy

### 8.1 Test locations

| Path | Coverage |
|---|---|
| `meal_planner_api/test/meal_planner_api/persistence/accounts/account_membership_test.exs` | Schema changeset validations, `Ecto.Enum` exhaustiveness, FK constraints. |
| `meal_planner_api/test/meal_planner_api/accounts_membership_test.exs` | Use cases: invite/accept/list/remove/leave/switch/seat-cap; owner uniqueness; concurrent seat-cap race. |
| `meal_planner_api/test/meal_planner_api/services/invite_service_test.exs` | Token entropy, hashing, single-use, expiry. |
| `meal_planner_api/test/meal_planner_api_web/plugs/load_current_membership_test.exs` | Virtual-membership synthesis for `access_v1`; real load for `access_v2`; `membership_id_required` on missing claim. |
| `meal_planner_api/test/meal_planner_api_web/plugs/enforce_account_scope_test.exs` | `403 account_mismatch` on URL/JWT mismatch. |
| `meal_planner_api/test/meal_planner_api_web/controllers/membership_controller_test.exs` | Index, remove; cross-Account isolation. |
| `meal_planner_api/test/meal_planner_api_web/controllers/invite_controller_test.exs` | Create, accept (existing + new User), replay, expiry. |
| `meal_planner_api/test/meal_planner_api_web/controllers/account_lifecycle_controller_test.exs` | Switch, leave, owner-leave blocked. |
| `meal_planner_api/test/meal_planner_api_web/controllers/auth_controller_test.exs` | Dual-write token issuance + flag flip; refresh preserves `typ`. |
| `meal_planner_api/test/meal_planner_api_web/channels/membership_scoped_channel_test.exs` | Cross-Account join rejected; multi-familia two-socket scenario; `handle_in` cross-Account entity id rejected. |
| `meal_planner_api/test/support/migration_sanity_test.exs` | Loads every migration forward + rollback, asserts `check_account_membership_invariants()` holds at the head. |
| `meal_planner_api/test/meal_planner_api/subscriptions_test.exs` | `policy_for_account/1` resolves by `plan`; `:family_6` / `:trial` rows present. |

### 8.2 Factory macros (Q6)

```elixir
# test/support/factory.ex — additions only, existing macros preserved.
defmodule MealPlannerApi.Factory do
  use ExMachina.Ecto, repo: MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Accounts.{Account, User, AccountMembership}
  alias MealPlannerApi.Auth.Guardian

  # Q6 — create a User with N memberships across N Accounts in one call.
  def create_user_with_memberships_factory do
    %User{
      email: sequence(:email, &"u#{&1}@example.com"),
      name: sequence(:name, &"User #{&1}"),
      role: :member
    }
  end

  def user_with_memberships(user_attrs, memberships_spec \\ []) do
    user = insert(:user, user_attrs)

    Enum.each(memberships_spec, fn {account_attrs, role} ->
      account = insert(:account, account_attrs)

      insert(:account_membership, %{
        account_id: account.id,
        user_id: user.id,
        role: role,
        status: :active,
        joined_at: DateTime.utc_now()
      })
    end)

    user |> Repo.preload(memberships: :account)
  end

  # Q6 — issue an access_v2 token (used by every controller test).
  def issue_access_v2_token(user, membership) do
    claims =
      MealPlannerApi.AccountsMembership.claims_for(user, membership.account, membership)

    {:ok, token, _claims} =
      Guardian.encode_and_sign(user, claims, token_type: "access")

    token
  end
end
```

Usage in a test:

```elixir
user =
  user_with_memberships(
    %{email: "ana@example.com"},
    [
      { %{plan: :individual, name: "Personal" }, :owner },
      { %{plan: :family_4,   name: "Family"  }, :member }
    ]
  )

# Default active membership (first one inserted) — switch-account tested separately.
membership = List.first(user.memberships)
token = issue_access_v2_token(user, membership)
```

### 8.3 Migration sanity check

The migration test in `test/support/migration_sanity_test.exs` runs:

1. `mix ecto.drop && mix ecto.create && mix ecto.migrate` from a clean DB.
2. Asserts all four `subscription_plans` rows exist.
3. Inserts fixture `users` + `accounts` matching the pre-Phase-A shape.
4. Runs the backfill migration's `check_account_membership_invariants()`
   SQL helper and asserts zero violations.
5. `mix ecto.rollback` to the pre-Phase-A snapshot, then re-runs `migrate`
   to confirm idempotency.

### 8.4 Dual-write testing

A dedicated test in `auth_controller_test.exs` exercises both paths:

- `test "issues access_v1 when MEAL_PLANNER_TENANCY_V2=false"` — boot config
  `tenancy_v2_only: false`, hit `/api/auth/password`, decode the JWT, assert
  `claims["typ"] == "access"`.
- `test "issues access_v2 when MEAL_PLANNER_TENANCY_V2=true"` — set
  `tenancy_v2_only: true` via `Application.put_env/3` and reload the test
  pipeline; assert `claims["typ"] == "access_v2"` and the claim set matches
  §3.2 exactly.
- `test "access_v1 token verifies after flip"` — issue an `access` token
  pre-flip, then set `tenancy_v2_only: true`, hit a `:auth`-piped route,
  assert `current_membership.account_id` resolves from the virtual
  fallback path (Q1 marker is set on the synthesized struct).
- `test "access_v2 token without membership_id is rejected"` — encode a JWT
  with `typ: "access_v2"` but no `membership_id`; assert
  `401 membership_id_required`.

### 8.5 Cross-Account isolation test

```elixir
test "user cannot read Account_B via Account_A-scoped JWT", %{conn: conn} do
  user = user_with_memberships(%{email: "u@example.com"}, [
    { %{plan: :family_4, name: "A" }, :owner },
    { %{plan: :family_4, name: "B" }, :member }
  ])
  membership_a = Enum.find(user.memberships, &(&1.account.name == "A"))
  token = issue_access_v2_token(user, membership_a)
  account_b = Enum.find(user.memberships, &(&1.account.name == "B")).account

  conn =
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> get(~p"/api/accounts/#{account_b.id}/memberships")

  assert json_response(conn, 403)["error"] == "account_mismatch"
end
```

## 9. Rollout Plan

### 9.1 Deploy order

| Order | PR | Size (forecast) | Env-var state | What ships |
|---|---|---|---|---|
| 1 | `tenancy/migration-and-dual-write-guardian` | ~400 LOC | `MEAL_PLANNER_TENANCY_V2=false` (default) | 4 migrations, `AccountMembership` schema, `LoadCurrentMembership` plug, dual-write Guardian. No controller surface change; both `access_v1` and `access_v2` verify paths live; only `access_v1` is issued. |
| 2 | `tenancy/accounts-membership-context-and-invite-service` | ~500 LOC | unchanged | `AccountsMembership` context, `InviteService`, `Subscriptions.policy_for_account/1` rewrite, `data/*_repo.ex` query rewrites, `Accounts` registration atomicity fix. No new routes; controllers still read `current_user.account_id`. |
| 3 | `tenancy/controllers-channels-and-docs` | ~600 LOC | **flip to** `MEAL_PLANNER_TENANCY_V2=true` after deploy | New controllers, route additions, channel sweep, factory extensions, `ARCHITECTURE.md` updates. `AuthController` now consults the flag (Q4) and mints `access_v2`. |

### 9.2 PR-by-PR verification

- **PR 1**: `mix ecto.migrate && mix ecto.rollback` round-trip on a fresh
  DB; `mix precommit`; `migration_sanity_test` passes. Backfill is exercised
  with a populated fixture (1k users).
- **PR 2**: `mix precommit`; new unit tests for `AccountsMembership`,
  `InviteService`, `Subscriptions`; existing controller tests still pass
  because the pipeline synthesizes `current_membership` from
  `current_user.account_id`.
- **PR 3**: `mix precommit`; new controller + channel tests; manual smoke
  test against a local DB (curl invite → accept → switch → leave → cross-
  Account join rejection). `mix dialyzer` (if configured) clean.

### 9.3 Smoke test (post-PR-3 deploy)

```
# 1. Owner registers, gets access_v2 token.
TOKEN=$(curl -s -X POST /api/auth/password -d '{"mode":"register", ...}' | jq -r .access_token)

# 2. Owner invites a member.
curl -X POST /api/accounts/<account_id>/invites -H "Authorization: Bearer $TOKEN" \
     -d '{"email":"ana@example.com"}'

# 3. Invitee accepts.
curl -X POST /api/invites/<token>/accept -H "Authorization: Bearer $TOKEN"

# 4. Owner lists roster.
curl /api/accounts/<account_id>/memberships -H "Authorization: Bearer $TOKEN"

# 5. Owner switches to another account (after multi-familia setup).
curl -X POST /api/auth/switch-account -H "Authorization: Bearer $TOKEN" \
     -d '{"membership_id":"<other-id>"}'

# 6. Member leaves the family account.
curl -X POST /api/accounts/<account_id>/leave -H "Authorization: Bearer <member-token>"

# 7. Owner attempts to leave → 403 cannot_leave_owned_account.

# 8. WS smoke: open two sockets, one per active Account, assert each
#    receives broadcasts only for its own topic.
```

### 9.4 Rollback

- **PR 1**: `mix ecto.rollback` of the four Phase A migrations. The down
  migration restores `users.account_id NOT NULL` after backfilling from
  the destroyed memberships. New tables persist but are unused.
- **PR 2**: `git revert` PR 2. New context and `InviteService` are dead
  code; legacy `Accounts` keeps working because the controller still reads
  `current_user.account_id`.
- **PR 3**: `git revert` PR 3. New routes return 404; legacy endpoints
  keep working. Set `MEAL_PLANNER_TENANCY_V2=false` and restart to stop
  minting `access_v2` tokens. Existing `access_v2` tokens expire on their
  normal TTL.
- **Catastrophic**: stop the API, drop `account_memberships`, drop
  `accounts.plan`, restore `accounts.account_type` from the migration
  snapshot. Total time: <30 minutes if the migration snapshot is current.

## 10. Resolved Design Decisions

These 10 questions were flagged in the spec for `sdd-design` to resolve.
Each is a one-line resolution the design has already incorporated above.

| # | Question | Resolution |
|---|---|---|
| **Q1** | Virtual membership shape (when JWT is `access_v1` and no `membership_id` claim exists) | Synthesize an in-memory struct: `%AccountMembership{id: nil, status: :active, joined_at: nil, __synthesized__: true}` populated from `current_user.account_id` + `current_user.role` + `Account.plan`. The `__synthesized__: true` marker lets tests assert which path populated the assign. No row is inserted. |
| **Q2** | Backfill SQL location | PostgreSQL function `check_account_membership_invariants()` is invoked at the **end** of the backfill migration's transaction; the migration rolls back if any check fails. A test re-runs the function after the migration completes to assert a clean steady state. |
| **Q3** | Status enum | Three values: `:active | :invited | :suspended`. Leave and remove operations **hard-delete** the row (no `:left`/`:removed` status). Re-invitation is permitted on a `:suspended` row; the app layer overwrites `invite_token_hash` and `invite_expires_at` and keeps the row. Owner is hard-protected by the application layer — never removed by any handler. |
| **Q4** | JWT claims (`access_v2`) | Adds `membership_id`, `plan`, `role`, `status` to the existing claim set (`sub`, `account_id`, `email`, `name`, `iat`, `exp`). `access_v1` is unchanged. Refresh preserves the original `typ` (no silent re-scoping). |
| **Q5** | Dual-write TTL | Issuance of `access_v1` is gated by `Application.get_env(:meal_planner_api, :tenancy_v2_only, false)` (env: `MEAL_PLANNER_TENANCY_V2`). Verification accepts both `typ` values indefinitely until the follow-up change `tenancy-v2-hardening` ships after the React Native client gains `current_membership` consumption. The flip is the only cutover step. |
| **Q6** | Test factories | New `user_with_memberships/2` macro accepting `[{account_attrs, role}, ...]` and preloads `memberships: :account`. New `issue_access_v2_token/2` helper builds claims via `AccountsMembership.claims_for/2` and encodes with `Guardian`. Existing macros preserved. |
| **Q7** | Invite token | 32 bytes of `crypto.strong_rand_bytes/1`, URL-safe base64 (no padding) → ~43-char plaintext string. SHA-256 hashed before storage. TTL = 7 days. Single-use: `accept` consumes the row's `invite_token_hash` and `invite_expires_at` (sets both to `NULL`). Replay returns `410 invite_token_used`. |
| **Q8** | Channel backward compat | `LoadCurrentMembership.membership_from_socket/1` returns `current_membership` if present; otherwise synthesizes from `current_user.account_id` + `current_user.role` (legacy path). Channels read only `current_membership.account_id` — the same code path serves both token types. |
| **Q9** | Index names | `account_memberships_user_id_account_id_index`, `account_memberships_account_id_status_index`, `account_memberships_user_id_status_index`, plus the partial unique index `account_memberships_active_account_user_unique_index`. Naming aligned with the project's existing convention (`create index(:users, [:account_id])` style — `meal_planner_api/priv/repo/migrations/20260322090000_create_accounts_and_users.exs`). |
| **Q10** | `subscription_plans` seed | Add `:family_6` (`max_users: 6`, `max_planning_days: 30`, `revenuecat_entitlement_id: "family_6"`) and `:trial` (`max_users: 6`, `max_planning_days: 30`, `revenuecat_entitlement_id: "trial"`). `:trial` is reserved for the follow-up change that wires the trial-expiration timer (grill 2026-06-16). Existing `:individual` and `:family_4` rows are kept and matched by name. |

## 11. References

- **Proposal**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/proposal.md`
- **Specs** (6, in canonical order):
  1. `…/specs/account-membership.md`
  2. `…/specs/invite-and-accept.md`
  3. `…/specs/multi-familia-switch-account.md`
  4. `…/specs/membership-scoped-channels.md`
  5. `…/specs/guardian-jwt-claims.md`
  6. `…/specs/auth-pipeline-and-current-resource.md`
- **PRD**: [vicenzogiordana/myfood#1](https://github.com/vicenzogiordana/myfood/issues/1) — Phase A.
- **Project CONTEXT**: `/Users/vicenzogiordana/Desktop/Progra/myfood/context.md` §3 (Monetization plans), §4 (Account / User / AccountMembership schema), §4b (deletion semantics — informs what we do NOT ship in Phase A).
- **API architecture**: `/Users/vicenzogiordana/Desktop/Progra/myfood/meal_planner_api/ARCHITECTURE.md` — Clean Architecture boundaries; Auth Flow section to be updated in PR 3.
- **API OpenSpec config**: `/Users/vicenzogiordana/Desktop/Progra/myfood/meal_planner_api/openspec/config.yaml` — `strict_tdd: true`, `max_changed_lines: 400`, `chained_pr_recommended_above: 400` → three chained PRs.
- **API sub-project conventions**: `/Users/vicenzogiordana/Desktop/Progra/myfood/meal_planner_api/AGENTS.md` — Phoenix v1.8 conventions, `mix precommit` for verification, Req for HTTP, `start_supervised!/1` for test processes.
- **Existing module patterns inspected**:
  `meal_planner_api/lib/meal_planner_api/persistence/accounts.ex`,
  `…/persistence/accounts/account.ex`,
  `…/persistence/accounts/user.ex`,
  `meal_planner_api/lib/meal_planner_api_web/auth_pipeline.ex`,
  `…/user_socket.ex`,
  `…/channels/calendar_channel.ex`,
  `…/controllers/auth_controller.ex`,
  `meal_planner_api/priv/repo/migrations/20260322090000_create_accounts_and_users.exs`,
  `meal_planner_api/priv/repo/migrations/20260326120000_create_subscription_plans.exs`.

## Next Step

Ready for `sdd-tasks`. The 10 design questions are resolved, the 3-PR chained
strategy is concrete, the file change set is enumerated, and every test
location / factory macro / API contract / channel pattern is documented
above to the level of granularity required for task generation.
