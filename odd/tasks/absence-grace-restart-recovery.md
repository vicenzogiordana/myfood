# Absence grace and restart recovery (issue #107, spec #93)

## Objective

Leaving or disconnecting keeps the Planning Session, its Workspace, the last
Proposal and the Household's slot for a 15-minute grace. A server restart
within the grace restores the session when its Member returns. Uncertain
operations are reconciled, never replayed; there is no unattended restart;
neither grace nor limits reset. On expiry the work is cancelled, the
Workspace discarded and the slot released. A Member whose access was revoked
cannot resume.

## Problem / why

Today the Planning Session ends as soon as its last subscriber is gone, and a
supervisor shutdown expires its row, so a dropped connection or a deploy
loses the chat and the Proposal (user stories 86-89, 101).

## Scope

- `PlanningAgent.Session`: absence (no subscribers) starts a grace timer and
  fixes the lease to the grace deadline; no new model call starts and no
  save is accepted while absent; return within grace cancels the timer.
- Recoverable storage: `planning_agent_recoveries` table holding a snapshot
  (transcript, Workspace, allowance, pending limit, the model adapter's
  recoverable part — never credentials) written as state changes; deleted
  whenever the Planning Session ends (cancel, expiry, lost lock, commit).
- `Session.resume/2`: rejoins the live process, or recovers a dormant one
  from its snapshot when the Member returns, after checking the membership
  is still active. Shutdown/crash keeps the session recoverable.
- Model behaviour: optional `recoverable/1` + `recover/2`; OpenAI adapter
  keeps the spend ledger with unsettled reservations counted as spent.
- Channel: `resume_session` event; `cancel_session` also cancels a dormant
  session.
- Docs: Session moduledoc, CHANNELS.md, CONTEXT.md (Grace).

Out of scope: #108 execution bounds hardening, #109 battery.

## Constraints

- Tests through public interfaces (Session, channel), fictitious fixtures.
- `MYFOOD_TEST_DATABASE=meal_planner_api_test107` for every test run.

## Tasks

- [x] T1 Absence grace in a live session: grace timer, lease, no model calls
      or saves while absent, resume of the live process, expiry discards and
      frees the slot. Route: direct inline (single deep module + its test;
      writer delegation not available to this bounded worker).
- [x] T2 Restart recovery: snapshot storage + migration, recoverable model
      state, `resume/2` recovering a dormant session without replay, limits
      kept, revoked Member refused, dormant cancel. Route: direct inline.
- [x] T3 Channel wiring (`resume_session`, dormant cancel) and docs.
      Route: direct inline.

## Acceptance criteria

- [x] Reconnecting within 15 minutes restores the Workspace and Proposal
- [x] A restart within the grace restores the session without replaying uncertain operations
- [x] No model calls or saves happen while the Member is absent
- [x] Grace expiry discards the Workspace and frees the slot
- [x] A Member removed from the Household cannot resume a recovered session

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test107 mix test` (full suite)
- `mix precommit`

## Progress / evidence

- T1 `8b9981f` — RED: session_grace_test 0/7 (resume undefined, lease 120 s,
  confirm not refused). GREEN: 7 passed; planning agent + channel suites 234 passed.
- T2 `03d024c` — RED: recovery + adapter tests 28/37. GREEN: 44 passed;
  stress-run 12x stable after fixing a dead-pid Registry race in `whereis/1`
  (a just-stopped session is now treated as not running) and syncing tests
  with the session before reading state or killing it.
  `session_test` "supervisor shutdown releases the lock" was intentionally
  changed: a shutdown is a restart and now keeps the session recoverable.
- T3 (channel + docs) — RED: 3 new channel tests failed; GREEN: 19 passed.
- Full suite: `MYFOOD_TEST_DATABASE=meal_planner_api_test107 mix test` →
  1199 passed, 25 skipped. `mix precommit` → passed.

## Decisions

- The grace deadline is the `planning_sessions.lease_expires_at`: while the
  Member is present it is renewed to now + max(grace, 120 s); when they leave
  it is fixed to leave time + grace and a restart never extends it.
- Each new absence starts a new grace; "never resets" applies to restarts.
- Snapshot = `term_to_binary` (decoded with `:safe`) of transcript,
  Workspace, allowance, pending limit and `Model.recoverable/2` (OpenAI: the
  spend with open reservations counted as spent; never the config/API key).
- Confirmation in flight is reconciled by the row status: the commit deletes
  the snapshot inside the same transaction and a committed row is never
  restored.

## Next step

PR review (Jorge el Curioso gate).
