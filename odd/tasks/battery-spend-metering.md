# Battery spend metering settles at real billing

Issue: #144 — Part of spec #93.

## Objective

The battery's per-run spend (and the spend ceiling it enforces) must match what the
provider actually bills: each call settled from the response `usage` (and
`usage.iterations`), and the worst case kept only when the outcome is unknown.

## Problem / why

The 2026-10-19 battery (`claude-opus-5-5`, 43 runs reaching the model) recorded about
US$0.90 per run (39,717,514 micro-USD); the Anthropic Console billed US$1.40 for the
window (about US$0.03 per run).

## Root cause (verified)

`Model.ClaudeMessages` already settles each call exactly from `usage` and
`usage.iterations` (input, cache write, cache read, output). The over-count is in the
shared battery wrapper `Battery.MeteredModel`: it meters `spent + reserved` at every
checkpoint and keeps the **peak** (`max(old, new)`). The checkpoint fires after the
worst-case reservation (about 720,000 micro-USD of `max_tokens` output for the requested
model and one fallback attempt, plus every request byte at the highest input price), so
each run was metered at its largest in-flight reservation, not at what it settled to.
Reproduced by `metered_model_test.exs`: metered 795,294 vs settled 93,386 micro-USD.

The same wrapper meters the OpenAI adapter, so the fix covers both providers.

Consequences: the 40,000,000 micro-USD battery ceiling ran out after 43 runs (the
remaining runs `spend_cap_reached` at 0 spend), and the battery cost gate failed.

## Scope

- `Battery.MeteredModel`: meter the latest `spent + reserved`, not the peak.
- Tests: realistic Claude response bodies (cache fields, `cache_creation`,
  `usage.iterations`) asserting settled micro-USD, through the adapter and through the
  meter; failed and killed calls keep the worst case.

Out of scope (follow-up, product/config decision): the per-session cap. With
`max_tokens: 16_000` and fallbacks on, one call reserves at least ~US$0.72 before any
input bytes, so a US$1 per-session cap refuses the next call once the request body passes
roughly 25 KB, even though the settled spend is cents (R3 run 3 ended in
`spend_cap_reached`). Raising the cap or lowering `max_tokens` / `max_fallback_attempts`
fixes it; the reservation is a genuine worst case and is kept.

## Checklist

- [x] T1 Reproduce with a failing test and fix `MeteredModel` to meter the latest state
      (route: inline, one source file + one new test file; RED observed: 795294 vs 93386).
      Commit: 0a463c6.
- [x] T2 Realistic Claude response test asserting exact settled micro-USD in
      `claude_messages_test.exs` (characterization: passed on first run, confirming the
      adapter settles correctly). Commit: 0a463c6.

## Acceptance criteria

- Root cause identified with a reproducing test: done (T1).
- A successful call settles exactly from reported usage: asserted (T1, T2).
- Worst case kept only when usage is unknown (failed or killed call): asserted (T1).
- Realistic Claude body with `usage.iterations` and cache fields asserts settled
  micro-USD: done (T1, T2).
- Battery per-run spend in line with real billing: the meter now reports settled spend
  (93,386 micro-USD for the two-call fictitious run instead of 795,294). Not re-measured
  against the Console: no real API call is made in this change.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test144 mix test`
- `mix precommit`
