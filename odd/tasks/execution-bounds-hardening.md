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

- [x] Each deadline and retry budget is enforced and observable in session tests
- [x] Non-retryable errors are not retried
- [x] Three no-progress attempts stop the run and ask the Member
- [x] Continuing past a limit requires explicit authorization
- [x] Outcome kinds are reported for tools and runs
- [x] Streamed events contain no raw tool output or model reasoning

## Tasks

- [x] T1 Per-call deadlines, retry budgets and error classification
  (route: inline, single bounded worker; trigger evidence: worker owns the
  whole issue). Commit: 5863711.
- [x] T2 Session-level allowance, no-progress detection and authorization
  to continue (route: inline). Commit: af7a495.
- [x] T3 Outcome kinds for tools and runs, event allowlist, missing is never
  zero (route: inline). Commit: the T3 commit on this branch
  (feat(planning-agent): report outcome kinds ...), which also carries this
  checkbox update.

## Checks

- `MIX_TEST_PARTITION=108 MYFOOD_TEST_DATABASE=meal_planner_api_test108 mix test`
- `mix precommit`

## Progress and evidence

- T1 (5863711; e1a7ab7 before rebase): RED observed for 8 session bounds tests, 5 OpenAI status
  classification tests and the closed-port test; GREEN after wiring. Planning
  agent suite 104 passed; full suite 1054/1055 with one failure in the legacy
  `PlanningChannelTest` that passes on rerun (flaky, untouched code).
- T2: RED observed for 8 allowance session tests; GREEN after wiring.
  Planning agent and agent channel suites 115 passed.
- T3: RED observed for 8 outcome/streaming session tests and the unknown
  usage adapter test; GREEN after wiring. Planning agent and agent channel
  suites 123 passed. `mix precommit` (partition 108): exit 0, 1074 passed,
  25 skipped.

## Next step

Native review gate (Jorge el Curioso) on the PR. Follow-ups outside #108:
absence grace (#107) can reuse the session presence flag that already stops
retries; candidate costs remain unpriced until the purchase slice (#100), so
every optimizer plan is reported as `partial` with `estimated_cost` missing.
