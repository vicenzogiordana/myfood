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

- [ ] T1 Absence grace in a live session: grace timer, lease, no model calls
      or saves while absent, resume of the live process, expiry discards and
      frees the slot. Route: direct inline (single deep module + its test;
      writer delegation not available to this bounded worker).
- [ ] T2 Restart recovery: snapshot storage + migration, recoverable model
      state, `resume/2` recovering a dormant session without replay, limits
      kept, revoked Member refused, dormant cancel. Route: direct inline.
- [ ] T3 Channel wiring (`resume_session`, dormant cancel) and docs.
      Route: direct inline.

## Acceptance criteria

- [ ] Reconnecting within 15 minutes restores the Workspace and Proposal
- [ ] A restart within the grace restores the session without replaying uncertain operations
- [ ] No model calls or saves happen while the Member is absent
- [ ] Grace expiry discards the Workspace and frees the slot
- [ ] A Member removed from the Household cannot resume a recovered session

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test107 mix test` (full suite)
- `mix precommit`

## Progress / evidence

(pending)

## Next step

T1.
