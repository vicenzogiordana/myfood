# Feature: Pantry, cart, and inventory lifecycle (#37)

## Contract

- Issue #37; parent #29 stories 18–22 and 33; dependencies #30/#36 merged.
- Branch `feat/issue-37-pantry-cart-inventory-pr1`; base/reviewed boundary `72802e5867f37dd54cc498198f703feb6f8850c7`.
- Current authorization: deliver issue #37 with conventional commits, push, and a linked PR; add `status:approved` to the issue and create a minimal English PR template. No reviews, merge, direct issue closure, force push, hook bypass, Git configuration changes, or subagents. This supersedes historical delivery restrictions below.
- Implementation and prior verification are complete. Delivery is in progress; the issue remains open. Unrelated working-tree changes are preserved and excluded.
- TDD off; behavior-focused tests were added during implementation. All tests and migration proof use only `MYFOOD_TEST_DATABASE=meal_planner_api_t1_verify_20261005_t1 MIX_ENV=test` from `meal_planner_api`. No database deletion or development/shared database access.

## Objective and decisions

Deliver Account-scoped, member-owned one-hour cart reservations with atomic removal/cancellation/expiry release; actual-quantity purchase and remainder return; retry idempotency; separately audited concurrent inventory movements; expired-account denial. Unpurchased shopping shortages are not physical stock. Reuse existing persistence; no unrelated recipe/auth/client work.

User chose separate inventory lots: preserve acquisition/expiry/price and historical movement identity. Availability sums usable lots only. Anonymous additions use deterministic default lot; never silently consolidate legacy rows. Freshness and FEFO must use the same effective-expiry rule as the inventory view (explicit expiry or existing acquisition/category inference). T1 excludes shopping/checkout changes; legacy direct checkout producer is T3.

## Tasks

- [x] **T1 — Atomic audited pantry movements.** Preserved and reverified lot-preserving, effective-freshness/FEFO inventory and atomic/idempotent cooking completion. Actual inventory migration down/up and independent-connection tests passed again. Completion here means implementation/test completion, not review or delivery.
- [x] **T2 — Cart reservation ownership and lease.** Account-scoped member carts, visible ownership/tokens, one-hour inactivity renewal, transactional removal/cancellation/expiry, automatic sweeper, foreign/stale authority denial. Real concurrent reservations and release rollback proven.
- [x] **T3 — Atomic actual-quantity purchase.** One authority shared by both checkout modules; actual stock lots, spend, audited movements, purchased lines and available remainders commit together. Missing reservation bypass rejected. Independent-connection duplicate/concurrent purchase and late-write rollback proven.
- [x] **T4 — Entitlement and full-lifecycle proof.** Existing capability pipeline reused; expired Account reserve/buy/adjust and realtime access denied when the existing enforcement rollout flag is enabled. Authenticated active/foreign Account behavior and reservation/release/expiry/purchase/inventory notifications proven; retries produce no duplicate purchase notifications or durable effects.

## Evidence and recovery

Historical first writer: 30 focused tests/format; prior verifier: 844 suite tests. Subsequent correction/scout failed with `assistant reported an error`, leaving partial edits and unsafe unique migration. No trace available. Resumed scout is functional; base schema already permits lots.

Inventory correction now implemented: canonical audited mutations, row/advisory locks, applied clamped deltas, deterministic default lots, preserved metadata and FEFO helper. Unsafe migration rewritten to reversible nonunique positive-stock lookup index, without UPDATE/DELETE/event rewriting. Executed only on new disposable `meal_planner_api_t1_verify_20261005_t1`; development/default test DB untouched. Test config now supports `MYFOOD_TEST_DATABASE` override; never drop this DB automatically.

Observed writer + independent verifier: focused four-file suite 36 passed; runtime 2 passed (distinct backend PIDs, barrier-started committed transactions); independent full suite 850 passed, 0 failures; scoped format and `git diff --check` passed. Exact suite commands use `MYFOOD_TEST_DATABASE=meal_planner_api_t1_verify_20261005_t1 MIX_ENV=test` from `meal_planner_api`: `mix test test/meal_planner_api/inventory_test.exs test/meal_planner_api/data/inventory_repo_test.exs test/meal_planner_api/services/inventory_service_test.exs test/meal_planner_api/inventory_concurrency_test.exs`; `mix test test/meal_planner_api/inventory_concurrency_test.exs --only runtime_db_concurrency --max-cases 1`; `mix test`.

Pending at accepted exception: migration proof checks IDs/event FK/nonunique index only, not complete records or actual migration up/down. Availability/FEFO filter explicit expiry only, unlike inferred expiry in view. Cooking completion still non-atomic. A freshness/migration-proof worker timed out while running `bash`; follow-up incident scout found the isolated DB restored/up, no live Mix process, and no other active DB sessions or locks. It reported partial source edits in LotFreshness, inventory context/persistence/service, inventory tests, service tests, and migration runtime test; no test result is proven. A subsequent bounded worker dispatch and read-only incident scout both failed with `assistant reported an error`; Git status showed no additional paths beyond those partial edits. On 2026-10-05 the user explicitly said to continue T1; a fresh worker attempt reconciled instructions (including preserving existing English category/fallback semantics) but again failed immediately with `assistant reported an error`. Follow-up Git status showed the same partial paths and no `mix test`/`mix ecto` process. With package writer/explorer roles unusable and no native Agent tool available, do not continue multi-file edits inline. Recovery requires a working delegated runtime; retain all edits and database state. Preexisting parse_voice_and_apply item-vs-ingredient mismatch is separate follow-up. `mix precommit` skipped because it mutates deps/global format; equivalent read-only final checks needed and skip must be reported. Existing warnings remain. One verifier invocation from repo root failed before tests, rerun in correct cwd passed.

Native assess unassessable from undeclared untracked scope: independent verifier ran per high-risk fallback. Inspect then ready selecting only new migration/runtime test; no START/lineage/review closure. Ambient projection includes unrelated tracked `.pi-lens` files; clean candidate scope pending. No commits; committed authored-line count 0. Preserve unrelated `.codegraph/`, `.pi-lens/`, `openspec` symlink, conversational spec and its task file.

Rollback: migration down removes only its new index; coherent code/test/config reversal restores prior defects, never unrelated changes or lot data. Keep T1 unchecked while cooking correction, review, and authorized commit evidence are pending.

### Authorized direct continuation — 2026-10-05

- Scope: reconciled the existing partial freshness implementation and completed bounded migration proof only. This supersedes the historical delegated-runtime recovery restriction above for this authorized continuation. No cooking atomicity, checkout, cart, T3, SDD artifacts, staging, commits, push, or review were performed.
- Freshness: the existing `LotFreshness` implementation is shared by the view, availability, and locked FEFO consumption. Retained explicit-expiry precedence, usable boundary day, and legacy English category rules (`produce=5`, `dairy=7`, `meat=3`) with the 14-day fallback for persisted Spanish categories. Added a policy regression test; existing cross-path tests cover inferred expiration and FEFO.
- Migration proof: replaced unsupported Sandbox migrator calls with a supervised unnamed dynamic Repo using `DBConnection.ConnectionPool` and two connections. Checks the actual database name before DDL; uses 5-second lock and 10-second statement timeouts. Actual `down/up` compares every persisted schema field of four duplicate lots and their events, plus all inventory index definitions; `after` restores the initially-up migration.
- Database safety: rechecked `meal_planner_api_t1_verify_20261005_t1` before use: migration up, six inventory indexes, no other sessions. After focused and full-suite execution, verified the same up version and six index definitions with no remaining sessions. No database was dropped; default/shared/development databases were not targeted.
- Normalization: scoped `mix format` completed on the eleven T1 Elixir/config/migration/test files before functional checks. Subsequent scoped `mix format --check-formatted` and `git diff --check` passed. Initial/current Git path sets are unchanged; unrelated dirty paths were preserved and the index remains empty.

All Mix commands below ran from `meal_planner_api` with `MYFOOD_TEST_DATABASE=meal_planner_api_t1_verify_20261005_t1 MIX_ENV=test`:

| Check | Exact command | Result |
| --- | --- | --- |
| Focused inventory, service, migration and independent-connection runtime | `mix test test/meal_planner_api/inventory_test.exs test/meal_planner_api/data/inventory_repo_test.exs test/meal_planner_api/services/inventory_service_test.exs test/meal_planner_api/inventory_concurrency_test.exs --timeout 30000 --max-cases 1` | 39 passed; 0.7 seconds; command bound 90 seconds |
| Full suite | `mix test --timeout 30000` | 853 passed; 17.1 seconds; command bound 120 seconds |

Remaining: atomic cooking correction is still separate and unimplemented; return this bounded result to the parent for review routing. Existing test warnings remain. The migrator additionally reports that preexisting version `202606070000000` sorts above `20260903000000`; this proof targets the exact version, but generic rollback ordering needs separate attention. `mix precommit` was not run because it unlocks dependencies and globally formats unrelated files; scoped normalization and full tests do not claim a warnings-as-errors gate. CodeGraph returned unrelated Python symbols for exact Elixir paths, so direct file inspection was used without index changes.

### Authorized direct cooking correction — 2026-10-05

This section supersedes the preceding statement that cooking remains unimplemented, not the pending review/delivery gate. The user authorized bounded cooking work while native review remains pending. No SDD, review lifecycle, staging, commit, branch change, push, PR, tooling configuration change, or subagent was used. T1 remains unchecked and unreviewed.

- Root cause: `CookingService.persist_finish/2` ignored independent session/meal update results, then committed each ingredient mutation separately. Neither completed-session nor cooked-meal state guarded retries. Completion now locks and re-reads the account-scoped session, then the account-scoped meal, inside one transaction. It checks both completion writes and rolls back all lot/event/completion changes on failure. Completed-session retries return zero new mutations; distinct sessions for the same cooked meal complete without another deduction.
- Ingredient deductions acquire existing logical-key locks in canonical ingredient/unit order and retain existing lot FEFO, freshness/category/fallback, planned-stock, clamping, and ingredient-operation count semantics. No recipe serving multiplier, cart, checkout, or T3 behavior was added. Identity resolution remains outside the completion transaction.
- Independent-connection testing exposed another transaction-boundary defect: `Ecto.Adapters.SQL.query(Repo, ...)` bypassed the dynamic Repo. Changed only that advisory-lock call to `repo.query(...)`; the installed Ecto SQL documentation explicitly requires this (or passing `get_dynamic_repo/0`). Runtime tests assert two ingredient advisory locks are held on the cooking backend before commit, not merely that final quantities happen to match.
- Changed paths: `meal_planner_api/lib/meal_planner_api/services/cooking_service.ex`, `meal_planner_api/lib/meal_planner_api/data/planning_repo.ex`, one line in the already-partial `meal_planner_api/lib/meal_planner_api/persistence/inventory.ex`, new `meal_planner_api/test/meal_planner_api/services/cooking_atomicity_test.exs`, and this task log. Existing partial/unrelated changes were preserved; the Git index remains empty.
- Runtime proof: eight behavior tests use a supervised non-Sandbox Repo restricted to the exact isolated database, with 3-second lock and 8-second statement timeouts. Barrier-started supervised workers prove distinct PostgreSQL backend PIDs, same-session and different-session duplicate protection, and separate meals sharing ingredients. Real database FK failures after earlier audit writes prove rollback for later inventory-event, meal, and session writes. Additional checks cover FEFO lots, expired/extra stock exclusion, actor attribution, retry timestamp stability, and foreign-account denial. Failure-injection triggers/functions are removed in `after`; fixture construction is transactional and successful fixtures have scoped cleanup.
- Failure evidence: first new-file run failed all eight tests during setup because the test lot omitted required `last_mutation_at`; no cooking code ran. Eight setup-only fixture sets were identified by exact account UUIDs and removed using a guarded transaction targeting only those newly created fixtures (8 meals, recipes, memberships, users, accounts; 16 ingredients; no inventory/events existed). No preexisting data or database was dropped. Corrected fixture creation then passed 8/8 in 0.6 seconds. The initial combined run passed 83/90, exposing the dynamic-Repo lock defect; cleanup left zero fixtures/triggers and no sessions. One targeted correction and same-seed rerun passed 90/90. These are diagnosed iterations, not a test-first RED/GREEN claim.

All commands below ran from `meal_planner_api` with `MYFOOD_TEST_DATABASE=meal_planner_api_t1_verify_20261005_t1 MIX_ENV=test`:

| Check | Exact command | Result |
| --- | --- | --- |
| Normalize only touched Elixir files before final functional checks | `mix format lib/meal_planner_api/data/planning_repo.ex lib/meal_planner_api/services/cooking_service.ex lib/meal_planner_api/persistence/inventory.ex test/meal_planner_api/services/cooking_atomicity_test.exs` | Passed |
| Focused inventory/cooking/controller/channel/migration/runtime | `mix test test/meal_planner_api/inventory_test.exs test/meal_planner_api/data/inventory_repo_test.exs test/meal_planner_api/services/inventory_service_test.exs test/meal_planner_api/inventory_concurrency_test.exs test/meal_planner_api/services/cooking_service_test.exs test/meal_planner_api/services/cooking_atomicity_test.exs test/meal_planner_api_web/controllers/cooking_controller_test.exs test/meal_planner_api_web/channels/cooking_channel_test.exs --timeout 30000 --max-cases 1 --seed 116791` | 90 passed, zero failures; 1.4 seconds; command bound 90 seconds |
| Full suite, once | `mix test --timeout 30000` | 861 passed, zero failures; 18.3 seconds; seed 842094; command bound 120 seconds |
| Final scoped format check | `mix format --check-formatted lib/meal_planner_api/data/planning_repo.ex lib/meal_planner_api/services/cooking_service.ex lib/meal_planner_api/persistence/inventory.ex test/meal_planner_api/services/cooking_atomicity_test.exs` | Passed |
| Whitespace/index checks | `git diff --check`; `git diff --cached --stat` | Passed; index empty |

Database checks used `PGPASSWORD=postgres psql -h localhost -U postgres -d meal_planner_api_t1_verify_20261005_t1 -X -v ON_ERROR_STOP=1 -c "..."` for `current_database()`, exact migration version `20260903000000`, all `pg_indexes` definitions for `inventory_items`, other sessions in `pg_stat_activity`, and leftover cooking fixture/trigger/function counts. Before reuse and after the full suite: exact target confirmed, migration up, the same six index definitions, and no other sessions. Final cooking fixture/trigger/function counts were all zero. Failure process inspection found no MyFood test/migration process; unrelated Elixir language servers and another project's test process were left untouched. Default/shared/development databases were not targeted. New runtime tests intentionally skip unless the exact isolated database environment is supplied.

Rollback boundary: reverse only the cooking-service transaction/guard changes, the two new PlanningRepo lock helpers, the single advisory-query routing change, the new cooking atomicity test file, and this log section. Do not revert whole preexisting partial inventory files, freshness policy, migration proof, config, or unrelated files. Reversal restores the old atomicity/retry defects; no data migration is needed.

Remaining risks/status: native review is still blocked before START by the unavailable intended-untracked JSON schema; no binding, approval, or review closure exists. No review was disabled or invoked here. T1 is not closed, and delivery/commit evidence remains pending authorization. This correction does not backfill or repair historically inconsistent partial completions. Existing test warnings and the migration numbering-order caveat remain unchanged. `mix precommit` was deliberately not run because it mutates dependency locks and globally formats; no warnings-as-errors gate is claimed. The Engram save attempt was rejected for multiple active sessions; no session identity was invented and the save was not retried.

`skill_resolution: paths-injected` — read `/Users/vicenzogiordana/.agents/skills/implement/SKILL.md` and `/Users/vicenzogiordana/.agents/skills/work-unit-commits/SKILL.md`; their commit/review suggestions did not override the explicit restrictions.

### Authorized whole-issue continuation — 2026-10-06

#### Recovery and scope

- First inspected Git state, this task log, OS processes, and the exact isolated database. The cancelled worker had left new `Cart`, `CartSweeper`, `ShoppingChannel`, lease schema/migration and checkout/controller wiring, but no new lifecycle tests or recorded completion. Cart migration `20261005000000` was already up. No MyFood test/migration process or other connection to the target database was active. Unrelated Elixir language servers were left alone.
- Read GitHub #37 and parent #29 without modifications. The parent requires actual purchased inventory at confirmation, including online purchase; delivery acknowledgement is now a non-mutating compatibility response. No client implementation or new product view is required by this backend ticket.
- CodeGraph returned no relevant code for the exact cart/shopping query. Used targeted source reads; no index/configuration maintenance. Read project `meal_planner_api/AGENTS.md` and both injected skills. No reviews, subagents, staging, commits, push, PR, issue edits/closure, or configuration changes were performed.

#### Completed behavior

- `Cart` serializes member reservations and purchase commands by Account, then locks/re-reads sessions and lines. Reservations have a member owner, session lease and per-line UUID token; a removed/re-reserved line gets a new token. A stale activity command cannot revive expired authority. Lease refresh covers the entire cart; viewing the shopping list does not count as activity. A supervised 30-second sweeper releases due leases without client requests.
- Expiry commits independently before a stale command is rejected, so rejection cannot roll back release. Removal and cancellation are atomic. The database enforces at most one draft cart per Account/member. Ownership, current membership, Account scope and active lease are checked before purchase.
- Purchase accepts all current reserved lines with explicit `quantity_milli` and per-line `total_cents`; zero quantity releases a line, under-purchase returns the exact remainder, and over-purchase records the actual amount without a negative remainder. A completed retry returns `already_purchased` with no new stock/spend/movement/event. Both checkout modules delegate to this authority; date-range-only checkout returns `reservation_required` instead of bypassing ownership. Delivery acknowledgement never creates stock.
- Purchase uses the canonical audited lot writer inside the same transaction as line/remainder changes and checkout spend. Each purchased line preserves acquisition time/price and checkout/actor provenance. Late audit, shopping-line and checkout failures roll back the complete outcome. Ingredient lock ordering remains canonical.
- Shopping output exposes reservation ownership, expiry, tokens and original per-line IDs under `items[].lines`, grouped by ingredient **and unit**. Removed erroneous read-time inventory subtraction that would subtract newly purchased stock again from returned remainders. Reconciled legacy lazy generation to use `ShoppingRebuilder` net shortages and to detect any existing matching line without failing on multiple purchased/remainder rows. Scoped the legacy single-item supermarket update to the active Account and removed its unrelated status toggle.
- Added `shopping:<account_id>` notifications for reservation, renewal, release, automatic expiry, purchase and inventory changes. Broadcast delivery revalidates active membership and existing Account capability; expired/suspended members receive nothing. Purchase retries/failures emit no duplicate mutation event. Existing HTTP inventory mutations publish refresh notifications after success. Existing capability routing remains authoritative; no billing or rollout configuration was changed.

#### Client-facing contract

- Reserve: `POST /api/shopping-items/mark-cart` with `item_ids`, or the existing ingredient/date selector. Response includes `session_id`, `owner_user_id`, `lease_expires_at`, and `reservations` containing `item_id`, `reservation_token`, `quantity_milli`.
- Activity: `POST /api/cart/:session_id/activity`. Remove: existing mark-cart endpoint with `in_cart: false`, `session_id`, and `items` containing the item IDs and current reservation tokens. Cancel: `DELETE /api/cart/:session_id`.
- Confirm: `POST /api/checkout/confirm` with `session_id`, `checkout_type: physical|online`, and `items: [{item_id, reservation_token, quantity_milli, total_cents}]`. Every current reserved line must be represented; use quantity/cost zero for an unpurchased line. Old date-only purchase requests must refresh and reserve first.
- Realtime: authenticated `shopping:<active-account-id>` join; notifications are invalidation/update signals, not a second mutation endpoint. Clients can refetch the existing shopping/inventory endpoints. No new UI surface was added.

#### Verification evidence

All Mix commands ran from `meal_planner_api` with `MYFOOD_TEST_DATABASE=meal_planner_api_t1_verify_20261005_t1 MIX_ENV=test` and bounded tool timeouts. No test or migration command targeted another database.

| Check | Command / result |
| --- | --- |
| First focused implementation run | Three lifecycle/shopping files: 22/26 passed. Failures were legacy fixture memberships missing and an invalid test-only membership status. Corrected fixtures; no production authorization was weakened. |
| HTTP/channel test compilation | One invocation stopped before running tests because `connect/2` was imported from both ConnTest and ChannelTest. Excluded ConnTest's conflicting import. |
| Focused cart/shopping/HTTP/runtime after correction | Five files: 37 passed, 4.3 seconds. |
| Expanded cart runtime/migration proof | `mix test test/meal_planner_api/cart_concurrency_test.exs test/meal_planner_api/cart_test.exs --timeout 30000 --max-cases 1`: 21 passed, 2.3 seconds, seed 148129. |
| Final normalization | `mix format` on all changed tracked Elixir files and all new lifecycle/T1 Elixir files, before final functional checks. |
| Final focused regression | Exact command below: **139 passed**, 4.1 seconds, seed 134890, command bound 90 seconds. |
| Full suite, once at the end | `mix test --timeout 30000`: **887 passed**, 19.9 seconds, seed 885618, command bound 120 seconds. |
| Final format/whitespace/index | Scoped `mix format --check-formatted`, `git diff --check`, `git diff --cached --stat`: passed; index empty. |

Final focused command:

```sh
MYFOOD_TEST_DATABASE=meal_planner_api_t1_verify_20261005_t1 MIX_ENV=test mix test \
  test/meal_planner_api/inventory_test.exs \
  test/meal_planner_api/data/inventory_repo_test.exs \
  test/meal_planner_api/services/inventory_service_test.exs \
  test/meal_planner_api/inventory_concurrency_test.exs \
  test/meal_planner_api/services/cooking_service_test.exs \
  test/meal_planner_api/services/cooking_atomicity_test.exs \
  test/meal_planner_api_web/controllers/cooking_controller_test.exs \
  test/meal_planner_api_web/channels/cooking_channel_test.exs \
  test/meal_planner_api/cart_test.exs \
  test/meal_planner_api/cart_concurrency_test.exs \
  test/meal_planner_api/services/shopping_service_test.exs \
  test/meal_planner_api_web/controllers/shopping_controller_test.exs \
  test/meal_planner_api_web/controllers/cart_lifecycle_test.exs \
  test/meal_planner_api/data/shopping_repo_test.exs \
  test/meal_planner_api/persistence/shopping_test.exs \
  --timeout 30000 --max-cases 1
```

Independent-connection runtime tests hold different PostgreSQL backend connections at a barrier, then execute real committed cart transactions. They prove single-owner reservation, duplicate purchase, different-member purchases, purchase/cancel races, concurrent expiry, release rollback and purchase rollback after database FK failures. Test tasks and dynamic repositories are supervised; lock/statement timeouts are 3/8 seconds. No sleeps or uncontrolled retries are used. Failure-injection triggers/functions are removed in `after`, and committed fixtures have scoped cleanup.

#### Migration, rollback and cleanup

- Existing inventory migration `20260903000000` preserves lots/events and only adds a nonunique positive-stock index. Cart migration `20261005000000` adds nullable owner/lease/result/token columns, expiry lookup and unique active-member-cart indexes; it does not rewrite existing stock or shopping records.
- Cart migration proof performs actual exact-version `Ecto.Migrator.down/up` through a non-Sandbox Repo, compares every preexisting field of shopping/session/inventory/event rows and all shopping/session index definitions, and restores the up migration in `after`. It refuses to run down if **any** populated cart owner/lease/result/token metadata exists, even in the isolated database.
- Final read-only database checks: both migrations up; six inventory indexes unchanged; both cart indexes present; no other sessions; zero cart fixtures, inventory lots, movements, checkout sessions, shopping lines, or failure-injection triggers/functions remain. No database was dropped. No MyFood test/migration process remains.
- Rollback boundary: T2–T4 cart/sweeper/channel, shopping schema/persistence/service/checkout, controller/router/socket/application wiring, cart migration and lifecycle tests. Preserve T1 code/tests and unrelated changes. Down removes the new columns/indexes and therefore loses populated reservation metadata; do not roll it back over live carts without an explicit drain/export plan. Stock, purchased line quantities and existing spend columns are not dropped. The automated proof only rolls back unpopulated new columns.
- Preexisting migration version `202606070000000` sorts above both new versions. Use an explicitly targeted migration rollback, not generic `mix ecto.rollback --step 1`; do not renumber already-applied migrations casually. Existing compiler/test warnings remain. `mix precommit` was not run because it mutates dependency locks and globally formats; scoped format and full tests are not a warnings-as-errors claim.

#### Changed paths and delivery status

- Recovered T2–T4 paths: `lib/meal_planner_api/{application,cart,cart_sweeper,shopping_checkout}.ex`, `lib/meal_planner_api/services/shopping_service.ex`, `lib/meal_planner_api/persistence/shopping.ex`, `lib/meal_planner_api/persistence/shopping/{checkout_session,shopping_item}.ex`, `lib/meal_planner_api_web/{router,user_socket}.ex`, `lib/meal_planner_api_web/controllers/{shopping_controller,inventory_controller}.ex`, `lib/meal_planner_api_web/channels/shopping_channel.ex`, and `priv/repo/migrations/20261005000000_add_cart_leases.exs` (all under `meal_planner_api`).
- New proof: `test/support/cart_fixtures.ex`, `test/meal_planner_api/{cart_test,cart_concurrency_test}.exs`, `test/meal_planner_api_web/controllers/cart_lifecycle_test.exs`; updated existing shopping service/controller tests. This task log records the contract and evidence. T1 paths/config already present at recovery were preserved and normalized/reverified, not replaced.
- T1–T4 are implementation/test complete. No issue closure, review, commit, PR, deployment, or client adoption is claimed. The existing capability-enforcement rollout flag must be enabled in environments enforcing the approved expired-Account policy; this task did not change it. Legacy ownerless reservations are not backfilled, and historically inconsistent purchases/completions are not repaired (parent #29 excludes production-data migration).
- Engram discovery save was rejected because multiple active runtime sessions matched. No session identity was invented and no save retry was made; durable task evidence is recorded here instead.
- `skill_resolution: paths-injected`: `/Users/vicenzogiordana/.agents/skills/implement/SKILL.md`; `/Users/vicenzogiordana/.agents/skills/work-unit-commits/SKILL.md`. Explicit no-review/no-commit instructions override their suggestions.

### Authorized delivery — 2026-10-06

- Confirmed branch `feat/issue-37-pantry-cart-inventory-pr1` at `72802e5`, no existing matching PR, and `main` as the remote default branch. Added only `status:approved` to issue #37; retained `ready-for-agent` and its open state.
- Added the authorized minimal `.github/PULL_REQUEST_TEMPLATE.md`. Delivery includes the issue implementation, its tests/migrations/config, and this evidence log; the template is a separate documentation work unit.
- Prior 139 focused / 887 full-suite passing results and scoped format evidence above were not rerun for delivery. Reviews remain intentionally not run at user request; no review PASS is claimed. Broad `mix precommit` remains not run; actual Git hooks are not bypassed.
- Preserve and exclude `.pi-lens/`, `.codegraph/`, `openspec`, the conversational meal-plan specification, and its task document. Final commit identities, push confirmation, and PR URL are reported in the delivery response rather than recursive bookkeeping commits.
- `skill_resolution: paths-injected`: branch-pr, work-unit-commits, and cognitive-doc-design were read from the supplied paths.
