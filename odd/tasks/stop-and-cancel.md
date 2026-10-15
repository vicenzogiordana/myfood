# Stop and Cancel

Issue: #106 — Part of spec #93 (user stories 84, 84a, 84b, 85, 102).

## Objective

A Member can Stop the agent's current work while the Planning Session, Workspace and last
valid Proposal survive, and can Cancel the Planning Session, discarding the Workspace and
freeing the Household's slot (the Owner can also Cancel another Member's session). In both
cases in-flight work is halted within 5 s, a running optimizer OS process is force-killed,
late results are rejected, and the slot is released only once old work can no longer act.

## Problem / why

The tracer bullet (#96) already cancels a session and kills the running turn, but:

- there is no Stop: the only way to interrupt the agent ends the whole session;
- a Proposal shown during a turn lives only in the turn process until the turn ends, so
  interrupting that turn loses it;
- the optimizer OS process is killed asynchronously by a reaper after the turn dies, so the
  session can release the slot (Cancel) or accept new work (Stop) while the solver still runs.

## Decision: spend cap scope

The human clarified (2026-10-15) that the paid-service spend cap and cumulative token cap,
which bound OpenAI calls, apply **per Planning Session**, not per execution: Stop and new
Member messages never reset them. The ledger already lives in the session-owned model state;
this feature pins that with tests and aligns the docs and glossary (spec #93 says "per
execution").

## Scope

- `Session.stop/2` (session's Member only; the Owner's only extra power is Cancel) and the
  channel `stop` event.
- Workspace checkpoints from the running turn so Stop keeps the Workspace and last valid
  Proposal produced before the interruption.
- Synchronous force-kill of the turn's optimizer OS processes on Stop, Cancel, the time
  limit and session shutdown, before the session replies or releases its slot.
- Spend/token caps scoped to the Planning Session (tests + docs + glossary).

Out of scope: grace/recovery, confirmation (no committed confirmation exists yet, so "never
rolled back" has nothing to roll back), authorize-continuation.

## Tasks

- [x] T1 Stop halts the turn, keeps Workspace and last valid Proposal, rejects late results;
      channel `stop` event. Route: inline (single module family, already mapped).
- [x] T2 The optimizer OS process is gone when Stop/Cancel returns; slot released only after.
      Route: inline.
- [x] T3 Spend and token caps are per Planning Session (survive Stop and new messages); docs
      and glossary. Route: inline.

## Acceptance criteria

- Stop halts the loop within 5 s and keeps the Workspace and last valid Proposal
- Cancel ends the session, discards the Workspace and frees the slot
- An Owner can Cancel another Member's session; a non-Owner cannot
- The optimizer OS process is gone after Stop or Cancel
- Results arriving after Stop or Cancel are discarded
- Spend and token caps hold across the whole Planning Session

## Checks

- `MIX_TEST_PARTITION=106 MYFOOD_TEST_DATABASE=meal_planner_api_test_106 mix test`
- `mix precommit`

Note: `config/test.exs` does not append `MIX_TEST_PARTITION` to the database name; it reads
`MYFOOD_TEST_DATABASE`, which is used for isolation instead.

## Progress / evidence

- T1 + T2 — commit `ce19bd5` (`feat(planning-agent): add Stop and halt in-flight work on Stop
  and Cancel`). RED observed: `Session.stop/2` and `current_proposal/1` undefined, optimizer
  OS pid never reported, channel `stop` unhandled. GREEN: `session_stop_cancel_test.exs`
  (7 tests), port `on_os_process` test, 3 channel tests. Mutation check: removing the
  synchronous kill makes the "OS process gone" tests fail (1–2 of 2 per run, reaper race).
- T3 — commit `5b0fc3d` (`feat(planning-agent): scope spend and token caps to the Planning
  Session`). Characterization tests (`session_spend_caps_test.exs`): behaviour was already
  per session through the session-owned model state, so no RED; tests pin the decision.
- Design notes: the Scripted adapter now checkpoints a consumed step before running it (like
  a paid call's reservation), so a Stop never replays it; the Loop reports the Workspace after
  every tool call (`on_workspace`); `OsProcess.kill/2` sends SIGKILL and waits until the pid
  is gone (bounded at 4 s).
- Checks: planning agent + channel suites 83/83 passed 5 runs in a row; `mix precommit`
  exit 0, 1034 passed, 25 skipped (warnings are pre-existing in unrelated test files).

## Next step

Open the PR (Closes #106, Part of #93); review by the pipeline gate.
