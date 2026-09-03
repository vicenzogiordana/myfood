# Planning Sessions Specification

## Purpose
Ephemeral planning-session lifecycle on `planning:<account_id>`: per-(account, range) lock via Postgres EXCLUDE, durable lease, terminal statuses that hard-delete children but keep the session row for audit. Entitlement is re-checked on `start_planning`, not only at `join/3`.

## Requirements

### Requirement: Session start writes one active row per (account, range)
MUST insert one `planning_sessions` row in `:active` per `(account_id, range_from, range_to)`. A partial EXCLUDE constraint MUST reject overlapping active ranges on the same account with `{:error, :overlapping_range}` (no row written).

| Scenario | Given | When | Then |
|---|---|---|---|
| Happy start | eligible Account, no active session on the range | `start_planning` runs | `{:ok, %{session_id: ...}}` returned + `session_started` broadcast |
| Overlapping range rejected | active session on `[2026-03-01, 2026-03-08]` | another member starts `[2026-03-05, 2026-03-12]` | `{:error, :overlapping_range}`, no `planning_sessions` row written |
| Non-overlapping ranges coexist | active session on `[2026-03-01, 2026-03-08]` | another member starts `[2026-03-15, 2026-03-22]` | both remain `:active` concurrently |
| Ineligible Account refused | Account whose entitlement check returns false | `start_planning` runs | `{:error, :subscription_required}`, no row written |

### Requirement: Cancellation is owner-scoped and hard-deletes children
MUST allow the session owner to cancel their own session, MUST allow an Account `:owner` to cancel any member's session, and MUST reject any other actor cancelling a peer's session with `{:error, :forbidden}`. On cancellation MUST hard-delete that session's `planning_messages` + `planning_exceptions`, set the session row to `:cancelled`, and broadcast `session_cancelled`.

| Scenario | Given | When | Then |
|---|---|---|---|
| Owner cancels own session | session created by User A | User A calls `cancel_planning` | row → `:cancelled`, children hard-deleted, `session_cancelled` broadcast |
| Non-owner peer cancel rejected | User A's session + non-owner User B | User B calls `cancel_planning` on User A's session | `{:error, :forbidden}`, no state changes |
| Account owner cancels peer | User A's session + `:owner` User C | User C calls `cancel_planning` on User A's session | row → `:cancelled`, children hard-deleted, `session_cancelled` broadcast |

### Requirement: Lease expiry and lost-lock transition to terminal status
MUST persist `lease_expires_at` on every active session. A sweeper MUST mark stale rows `:expired`; an unexpected owner-process death MUST transition to `:lost_lock`. Both MUST hard-delete children, update the session row, and broadcast `session_expired` / `session_lost_lock`.

| Scenario | Given | When | Then |
|---|---|---|---|
| Sweeper expires stale lease | active session with `lease_expires_at` in the past | sweeper runs | row → `:expired`, children hard-deleted, `session_expired` broadcast |
| Owner crash → lost_lock | active session with monitored owner | owner exits abnormally | row → `:lost_lock`, children hard-deleted, `session_lost_lock` broadcast |

### Requirement: Confirm commits the session without hard-delete
MUST let an active session's owner call `confirm`. Confirm MUST atomically write scheduled meals + shopping cart AND transition the session row to `:committed` (NOT hard-deleted), preserving audit.

| Scenario | Given | When | Then |
|---|---|---|---|
| Confirm writes cart and commits | active session with completed proposal | owner calls `confirm` | scheduled meals + cart rows written AND row → `:committed` |

### Requirement: Audit trail after terminal transition
After `:cancelled | :expired | :lost_lock`, the session row MUST remain queryable with its terminal status, while `planning_messages` and `planning_exceptions` for that session id MUST return zero rows.

| Scenario | Given | When | Then |
|---|---|---|---|
| Terminal session has no children | session in `:cancelled` / `:expired` / `:lost_lock` | child tables queried by session id | both return zero rows AND session row still queryable |
