# Execution bounds hardening (#108, part of #93)

## Objective

Make planning agent execution bounded and honest: per-call deadlines and
retry budgets, no-progress detection, limits that stop and ask the Member,
outcome kinds for tools and runs, and progress-only streaming.

## Problem and why

The tracer bullet (#96) bounds a request only by a 5-minute deadline and a
per-request iteration count that resets with every Member message. Model,
solver and read calls have no own deadline or retry policy, every provider
error looks transient, repeated useless attempts are not detected, and runs
report no outcome kind. Spec #93 and the #86 contract require all of that.

## Product decisions applied

- Spend and token caps are per Planning Session (decision 2026-10-15, #118).
- The iteration cap counts model calls (OpenAI calls) per Planning Session:
  a new Member message never resets it; only the Member's authorization
  extends it (user decision 2026-10-15, "tope por sesion"). The 5-minute
  deadline stays per request, with human wait time excluded.
- Retries are not iterations; they stay inside the same time, spend and
  token allowance.

## Scope

- `CallBounds`: per-call deadline and retry budget (model 60 s / 5 retries,
  solver 120 s / 0 retries, read tools 30 s / 2 retries), increasing backoff,
  everything clipped by the global deadline, no retries while the Member is
  absent or for non-retryable errors.
- OpenAI adapter classifies provider errors (permission, invalid request,
  conflict are not transient).
- `Allowance`: session-level iteration and no-progress counters; limits stop
  the run and ask; `authorize_continuation` is the only way to continue.
- Outcome kinds (complete, partial, failure, cancelled, unknown) for every
  tool result and every run; missing data is never reported as zero.
- Session events pass an allowlist: no raw tool output or model reasoning.
- Optimizer port: a write to a dead subprocess is `optimizer_crashed`.

## Acceptance criteria

- [ ] Each deadline and retry budget is enforced and observable in session tests
- [ ] Non-retryable errors are not retried
- [ ] Three no-progress attempts stop the run and ask the Member
- [ ] Continuing past a limit requires explicit authorization
- [ ] Outcome kinds are reported for tools and runs
- [ ] Streamed events contain no raw tool output or model reasoning

## Tasks

- [ ] T1 Per-call deadlines, retry budgets and error classification
  (route: inline, single bounded worker; trigger evidence: worker owns the
  whole issue). Commit: see T1 evidence below.
- [ ] T2 Session-level allowance, no-progress detection and authorization
  to continue. Commit: see T2 evidence below.
- [ ] T3 Outcome kinds for tools and runs, event allowlist, missing is never
  zero. Commit: see T3 evidence below.

## Checks

- `MIX_TEST_PARTITION=108 MYFOOD_TEST_DATABASE=meal_planner_api_test108 mix test`
- `mix precommit`

## Progress and evidence

Filled per task with the commit identity and observed checks.
