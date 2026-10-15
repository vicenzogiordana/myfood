# Session start rate limit and concurrency caps (#118, part of #93)

## Objective

Bound aggregate planning agent load before production rollout: a per-Household
rate limit on Planning Session starts, and global concurrency caps on
model-provider calls and optimizer subprocesses. Harden runtime parsing of cap
and price environment variables so malformed values never crash boot.

## Problem and why

Spend and token caps bound one Planning Session only. Nothing stops one
Household from starting sessions back to back, nor many sessions from calling
the provider or spawning OR-Tools subprocesses at the same time. `runtime.exs`
parses cap and price variables with `String.to_integer`, so a typo raises at
boot.

## Product decisions applied

- The provider spend cap stays per Planning Session (#96). No per-Household,
  per-day or weekly aggregate spend ledger (decision 2026-10-15, comment on
  #118). The ledger acceptance criterion is dropped.
- Cap values are a human decision: they come only from configuration. When a
  limit is unconfigured, paid execution is refused with
  `spend_caps_unconfigured`.

## Scope

- `Session.start/2`: per-Household start rate limit (`max starts` per
  `window seconds`), counted from stored Planning Session rows inside the
  existing Household advisory lock; refusal `session_start_rate_limited`.
  Unconfigured limit refuses with `spend_caps_unconfigured`.
- `ConcurrencyLimiter`: global slot counter supervised by the planning agent;
  a slot is released when its holder finishes or dies (brutal kill included).
- OpenAI adapter: `max_concurrent_calls` is a mandatory cap (`init/1` refuses
  `spend_caps_unconfigured` without it); a call over the cap is refused with
  transient `provider_busy` before any spend is reserved.
- Optimizer port: `max_concurrent_runs`; a run over the cap is refused with
  `optimizer_busy` before a subprocess starts; unconfigured refuses with
  `optimizer_unconfigured`.
- `runtime.exs`: `Integer.parse` for caps, prices and the new limits; malformed
  input becomes nil.

Out of scope: aggregate spend ledger, cap on the number of active sessions
(dropped by the product decision above).

## Acceptance criteria

- [x] Session start is rate limited per Household
- [x] Global concurrency caps on provider calls and optimizer subprocesses are enforced
- [x] All new limits are configurable and refuse safely when unconfigured
- [x] Malformed cap or price env values do not crash boot and result in `spend_caps_unconfigured`
- [x] Tests cover each limit and the malformed-config case

## Tasks

Route for every task: inline in this bounded worker (the worker is itself the
delegated writer; no further delegation allowed).

- [x] T1 Session start rate limit per Household — `49f5f3b` (RED: 6/6 failing, GREEN: 6 passed)
- [x] T2 ConcurrencyLimiter + provider call cap in the OpenAI adapter — `c049d16` (RED: 11 failing, GREEN: 47 passed)
- [x] T3 Optimizer subprocess cap in the optimizer port — `e7bbae8` (RED: 3 failing, GREEN: 22 passed)
- [x] T4 Runtime env parsing hardening + config wiring + docs — `53ed7a0` (RED: 8/9 failing, GREEN: 9 passed)

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test118 mix test`
- `mix precommit`

## Notes

- A malformed price reads as unset and the adapter keeps its existing typed
  refusal for missing prices, `pricing_unconfigured`; a malformed cap (spend,
  token or provider concurrency) refuses with `spend_caps_unconfigured`.
  Either way paid execution never starts and boot never crashes.
- The start rate limit counts stored `planning_sessions` rows by `started_at`
  under the Household advisory lock, so it survives restarts and races.

## Progress

- Branch `feat/issue-118-rate-and-concurrency-caps`.
- Verification: `MYFOOD_TEST_DATABASE=meal_planner_api_test118 mix test`
  1232 passed, 25 skipped; `mix precommit` 1232 passed, 25 skipped.
- Next step: review of the PR.
