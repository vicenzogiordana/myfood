# Tasks: Ephemeral Planning Sessions and Range Locks

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~790 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 migrations+schemas+EXCLUDE → PR2 PlanningRepo+validate_ai_intent → PR3 Server+Sweeper → PR4 channel events → PR5 integration+precommit |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | PR | Test command | Runtime harness | Rollback |
|------|------|----|--------------|-----------------|----------|
| 1 | migrations + 3 schemas + EXCLUDE | PR1 | `mix test data/planning_repo_session_schema_test.exs` | `iex -S mix` + `mix ecto.migrate` | drop migration; remove schemas |
| 2 | PlanningRepo CRUD + validate_ai_intent | PR2 | `mix test data/planning_repo_test.exs services/generation_service_test.exs` | N/A — pure fns + Repo | revert repo+service diffs |
| 3 | PlanningSessionServer + Sweeper + supervisor | PR3 | `mix test generation/planning_session_server_test.exs generation/planning_session_sweeper_test.exs` | `iex -S mix` start supervisor | remove supervisor children; PR1+PR2 inert |
| 4 | PlanningChannel + AIChannel + re-check | PR4 | `mix test channels/planning_channel_test.exs channels/ai_channel_test.exs` | Phoenix.ChannelTest socket | revert channel diffs; PR3 server unreachable |
| 5 | integration + precommit | PR5 | `mix test --max-failures 10` | iex + 2 joined sockets | revert failing test only |

## Phase 1: Migrations + Schemas (PR1)

- [x] 1.1 RED: migration test asserts btree_gist enabled + 3 tables exist (`test/meal_planner_api/data/planning_repo_session_schema_test.exs`).
- [x] 1.2 GREEN: create migration — `CREATE EXTENSION btree_gist`, 3 `CREATE TABLE` (binary_id PK, FKs to accounts `on_delete: :delete_all`), partial EXCLUDE USING gist `(account_id WITH =, daterange(range_from, range_to, '[]') WITH &&) WHERE (status='active')`.
- [x] 1.3 GREEN: create `planning_session.ex` schema (account_id, range, status Ecto.Enum, lock_owner_user_id, lock_owner_membership_id, lease_expires_at, started_at, terminal_at) + start/cancel/expire/lost_lock/commit changesets.
- [x] 1.4 GREEN: create `planning_message.ex` schema (account_id, session_id FK, role, content, intent_kind nullable, inserted_at).
- [x] 1.5 GREEN: create `planning_exception.ex` schema (account_id, session_id FK, kind, note, inserted_at).
- [x] 1.6 GREEN: run `mix ecto.migrate` on dev DB clean; commit.

## Phase 2: Repo CRUD + Intent Validator (PR2)

- [ ] 2.1 RED: `describe "PlanningRepo.create_session/2"` — happy `:ok`; overlap → `:overlapping_range`; ineligible → `:forbidden` (`data/planning_repo_test.exs`).
- [ ] 2.2 GREEN: implement `create_session/2` — wrap `Repo.insert`; map Postgrex exclusion error → `:overlapping_range`.
- [ ] 2.3 RED: `describe "cancel_session/3"` — owner-cancel `:ok`; non-owner peer `:forbidden`; terminal → `:not_active`.
- [ ] 2.4 GREEN: implement `cancel_session/3` — `Repo.transaction` (status=:cancelled + `Repo.delete_all` children).
- [ ] 2.5 RED: tests for `expire_session/2`, `mark_lost_lock/2`, `mark_committed/2`.
- [ ] 2.6 GREEN: implement those three.
- [ ] 2.7 RED: `describe "validate_ai_intent/1"` — 3 accepted kinds + 4 forbidden keys + unknown → `:unknown_intent` (`services/generation_service_test.exs`).
- [ ] 2.8 GREEN: implement `validate_ai_intent/1` in `GenerationService` — closed set + recursive walk rejecting `:recipe_id`, `:proposal_id`, `:scheduled_meal_id`, DB-mutating keys.

## Phase 3: PlanningSessionServer + Sweeper (PR3)

- [ ] 3.1 RED: `describe "start_link/1"` + lifecycle tests (`generation/planning_session_server_test.exs`).
- [ ] 3.2 GREEN: implement `PlanningSessionServer` GenServer supervised under new `Generation.PlanningSessionSupervisor` (DynamicSupervisor) wired into `Generation.Supervisor`.
- [ ] 3.3 RED: `describe "apply_intent/2"` — forbidden key → `:forbidden_intent`; accepted intent mutates constraint state.
- [ ] 3.4 GREEN: implement `apply_intent` — calls `validate_ai_intent/1` then mutates state.
- [ ] 3.5 RED: `describe "lost_lock/1"` — `Process.monitor` + `:DOWN` abnormal reason → row `:lost_lock` + broadcast `session_lost_lock`.
- [ ] 3.6 GREEN: implement `handle_info({:DOWN,...})` → `mark_lost_lock` + broadcast.
- [ ] 3.7 RED: `describe "Sweeper"` — session with past `lease_expires_at` transitions to `:expired` (`generation/planning_session_sweeper_test.exs`).
- [ ] 3.8 GREEN: implement `PlanningSession.Sweeper` — periodic tick (`Application.get_env :planning_session_sweeper_interval, 30_000`); `UPDATE ... WHERE status=:active AND lease_expires_at < now() FOR UPDATE SKIP LOCKED RETURNING id`.

## Phase 4: Channel Events + Capability Re-check (PR4)

- [ ] 4.1 RED: `describe "PlanningChannel handle_in start_planning"` — happy + ineligible → `:subscription_required` + overlap → `:overlapping_range` (`channels/planning_channel_test.exs`).
- [ ] 4.2 GREEN: implement `handle_in("start_planning", ...)` — re-check `AccountAccess.eligible?/1` + `PlanningSessionServer.start_session` + broadcast `session_started`.
- [ ] 4.3 RED: `describe "handle_in cancel_planning"` — owner-cancel `:ok`; non-owner peer `:forbidden`; Account owner cancels peer `:ok`.
- [ ] 4.4 GREEN: implement `handle_in("cancel_planning", ...)`.
- [ ] 4.5 RED: `describe "AIChannel handle_in new_message"` — intent `:recipe_id` rejected (no forward); valid intent forwarded as `send_intent` on `planning:<account_id>`.
- [ ] 4.6 GREEN: modify `ai_channel.ex` — call `validate_ai_intent/1` after Gemini stream; `:ok` → broadcast `send_intent`; `:error` → reply error.
- [ ] 4.7 RED: `describe "PlanningChannel handle_in send_message"` — accepts validated intent + applies via `PlanningSessionServer.apply_intent`.
- [ ] 4.8 GREEN: implement `handle_in("send_message", ...)`.

## Phase 5: Integration Verification (PR5)

- [ ] 5.1 Run `mix test --max-failures 10` — full suite passes.
- [ ] 5.2 Manual e2e: 2 sockets on same `planning:<account_id>`; A starts; B overlap → `:overlapping_range`; B non-overlap → `:ok`; A cancels → `session_cancelled` on BOTH sockets.
- [ ] 5.3 Sweeper manual: insert `lease_expires_at` 1s past; wait 1 tick; assert `:expired` + broadcast.
- [ ] 5.4 Lost-lock manual: kill GenServer abnormally; assert row → `:lost_lock` + broadcast.
- [ ] 5.5 Run `mix precommit` — no new warnings.

## Threat Matrix Tasks

- [ ] TM-1 RED: parallel cancel-vs-sweeper race — 2 Tasks; assert exactly one of `{:cancelled, :expired}` wins.
- [ ] TM-1 GREEN: confirm `SKIP LOCKED` + `Repo.transaction` row-lock prevent race.
- [ ] TM-2 RED: supervisor restart — kill server pid; assert rehydrate from DB + broadcast `session_resumed`.
- [ ] TM-3 RED: owner-crash `:normal` MUST NOT trigger `:lost_lock` (`Process.exit(self, :normal)` → no transition).
- [ ] TM-4 RED: broadcast after process death — kill mid-session OR dead process → broadcast / `:expired` fires.