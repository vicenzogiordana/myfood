# Design: Ephemeral Planning Sessions and Range Locks

## Technical Approach

`planning_sessions` table holds per-(`account_id`, `range`) lock via Postgres partial EXCLUDE. Lifecycle owned by `Generation.PlanningSessionServer` under new `Generation.PlanningSessionSupervisor`; existing `Generation.Server` run/cart untouched (Out-of-Scope). `PlanningSession.Sweeper` expires stale leases via `UPDATE … RETURNING id` with `SKIP LOCKED`. Typed-intent boundary is `GenerationService.validate_ai_intent/1`, called only from `AIChannel.handle_in("new_message", ...)` after the Gemini stream; validated intents broadcast as `send_intent`. `AccountAccess.eligible?/1` re-checked on `start_planning`.

## Architecture Decisions

### GenServer placement + Sweeper
`Generation.PlanningSessionServer` (one per active session) under new `Generation.PlanningSessionSupervisor` (sibling of `Generation.Supervisor`). `PlanningSession.Sweeper` ticks `Application.get_env(:meal_planner_api, :planning_sweeper_interval_ms, 30_000)`. Rejected: extend `Generation.Server` (owns run+cart); per-session timers (lost on restart). `SKIP LOCKED` on sweeper UPDATE prevents races with `cancel_planning`.

### EXCLUDE migration (atomic)
`CREATE EXTENSION btree_gist` → `CREATE TABLE planning_sessions` → `EXCLUDE USING gist (account_id WITH =, daterange(range_from, range_to, '[]') WITH &&) WHERE (status='active')` → messages + exceptions tables → FKs to `accounts`. Mirrors binary_id / `on_delete: :delete_all` from the existing planning migration.

### Typed-intent boundary + AI seam
Pure `GenerationService.validate_ai_intent/1`; called from `AIChannel.handle_in("new_message", ...)` AFTER `AI.stream_response/4`, BEFORE any intent reaches `planning:<account_id>`. `PlanningChannel` MUST NOT accept AI intents. Rejected: validate in `PlanningChannel` (spec seam is `AIChannel`).

### Broadcast topic + event set
Reuse `planning:<account_id>` (same as `Generation.Server`, server.ex:573-582). New events: `session_started | session_cancelled | session_expired | session_lost_lock | session_committed | message_appended`.

### Confirm transition + hard-delete children
Reuse `Generation.Server.do_confirm/2` + `run_confirm_transaction/3` (server.ex:286-334, tested PR #18); after commit, `PlanningSessionServer.mark_committed/1` updates session row to `:committed`. `PlanningRepo.cancel_session/3`, `expire_session/1`, `mark_lost_lock/1` wrap `Repo.transaction/1`: update status + `Repo.delete_all` for messages + exceptions. Spec = hard-delete.

## Data Flow

```
PlanningChannel → start_planning → PlanningSessionServer.start_session
  ├→ AccountAccess.eligible?/1 → Repo.insert (EXCLUDE → :overlapping_range)
  └→ broadcast "session_started"
AIChannel → new_message → AI.stream_response → validate_ai_intent/1
  ├→ :ok → broadcast "send_intent" on planning:<account_id>
  └→ :error → push "ai_intent_error"
PlanningChannel → send_message → PlanningSessionServer.apply_intent
PlanningChannel → cancel_planning → PlanningSessionServer.cancel_session
  └→ Repo.transaction (status=:cancelled + delete children) → broadcast "session_cancelled"
Sweeper tick → UPDATE … RETURNING id → broadcast "session_expired"
Process.monitor DOWN → mark_lost_lock → broadcast "session_lost_lock"
PlanningChannel → confirm_proposal → Generation.Server.do_confirm → mark_committed → broadcast "session_committed"
```

## File Changes

| Path | Δ |
|------|---|
| `priv/repo/migrations/<ts>_create_planning_sessions_messages_exceptions.exs` | New |
| `lib/.../persistence/planning/{planning_session,planning_message,planning_exception}.ex` | New |
| `lib/.../data/planning_repo.ex` | +create_session, cancel_session, expire_session, mark_lost_lock, mark_committed, fetch_active_session_for_range, append_message, record_exception, list_messages_for_session, list_exceptions_for_session |
| `lib/.../services/generation_service.ex` | +validate_ai_intent/1 |
| `lib/.../generation/planning_session_{server,supervisor,sweeper}.ex` | New |
| `lib/.../web/channels/{planning_channel,ai_channel}.ex` | new handle_in clauses; AI validate + send_intent |
| `lib/.../application.ex` | wire new supervisor + sweeper |
| `test/.../{data,services,generation,channels}/*_test.exs` | per Testing Strategy |

## Interfaces / Contracts

```elixir
@spec GenerationService.validate_ai_intent(map()) ::
  {:ok, map()} | {:error, :forbidden_intent} | {:error, :unknown_intent}
@spec PlanningRepo.create_session(map()) ::
  {:ok, PlanningSession.t()} | {:error, :overlapping_range} | {:error, Ecto.Changeset.t()}
@spec PlanningRepo.cancel_session(session_id, actor_membership_id, actor_is_owner?) ::
  {:ok, PlanningSession.t()} | {:error, :forbidden | :not_active}
# expire_session/1, mark_lost_lock/1, mark_committed/1 — same shape
@spec PlanningRepo.fetch_active_session_for_range(account_id, Date.t(), Date.t()) ::
  {:ok, PlanningSession.t()} | {:error, :not_found}
@spec PlanningSessionServer.start_session(account_id, user_id, membership_id, {Date.t(), Date.t()}) ::
  {:ok, %{session_id: Ecto.UUID.t()}}
  | {:error, :overlapping_range | :subscription_required | term()}
@spec PlanningSessionServer.cancel_session(pid, session_id, %{is_owner?: boolean()}) ::
  :ok | {:error, :forbidden | :not_active}
```

## Testing Strategy

| Layer | What | How |
|-------|------|-----|
| Unit | `validate_ai_intent/1` happy/forbidden/unknown | Direct call |
| Unit | `PlanningRepo` math: terminal session has 0 child rows | Repo sandbox |
| Integration (DB) | EXCLUDE rejects overlap; non-overlap allowed | Ecto sandbox; catch `Postgrex.Error` |
| Integration (GS + Sweeper) | Lifecycle; stale lease → `:expired` | `start_supervised!/1` + `:sys.get_state/1` |
| Integration (channels) | New `PlanningChannel` + AI intent forward | `Phoenix.ChannelTest`; stub AI stream |
| E2E | All new events reach joined members | subscribe + `assert_receive` |

## Threat Matrix

Process integration applies. Routing/shell/VCS matrix does NOT apply (no shell/subprocess/PR automation in this change).

| Case | App | Response | RED test |
|------|-----|----------|----------|
| Owner DOWN → `:lost_lock` | Yes | `handle_info({:DOWN,…,reason})` → `mark_lost_lock/1` when reason abnormal | Abnormal exit → row + broadcast |
| Supervisor restart | Yes | `:transient`; rehydrate from DB row; broadcast `session_resumed` | Kill pid → rehydrate + broadcast |
| Sweeper race vs cancel | Yes | `UPDATE … RETURNING id` w/ `SKIP LOCKED`; cancel uses `Repo.transaction` row lock | Parallel tasks → exactly one terminal status |
| Broadcast after process death | Yes | Always `Phoenix.Channel.Server.broadcast!/4`; sweeper queries DB, NOT GS state | Kill mid-session OR dead process → broadcast / `:expired` fires |
| DynamicSupervisor `:max_children` | N/A | No default max; bounded by Account count + seat cap | n/a |

## Migration / Rollout

Single atomic migration. `:revenuecat_access_enforcement` flag (off; `channel_capability.ex:36-39`) gates join-time; mid-session re-check via `AccountAccess.eligible?/1` added regardless. No new feature flag.

## Open Questions

- `:committed` rows kept forever per audit; TTL/prune deferred.
- Lease = 120s (2 min, matches spec).
- UI surface for "another member is planning X" deferred to frontend.
- Cancel-mid-confirm race delegated to EXCLUDE + transactional discipline.
