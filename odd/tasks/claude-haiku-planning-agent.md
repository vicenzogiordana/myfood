# Run the planning agent on Claude Haiku 5.5 (#156)

PR: #157 (branch `feat/claude-fallbacks-toggle`). Parent spec: #93.

## Objective

Run the planning agent on Claude Haiku 5.5. Findings, changes and battery
evidence are tracked on issue #156.

## Review rounds

### Round 1 (Jorge el Curioso)

- [x] R1.1 Failure notice blamed the service for the user-caused
  `fixed_meal_unavailable` error. `Loop.service_failure?/1` matched any
  error ending in `_unavailable`, so a fixed meal whose Recipe is gone
  produced "This is a problem on our side, not with your request."
  - Route: inline (one lib file, one test).
  - Fix: explicit deny clause for `"fixed_meal_unavailable"` before the
    suffix regex in `loop.ex`. Notice wording, tool error names and limit
    logic unchanged.
  - Test: `session_bounds_test.exs` "a run cut by an unavailable fixed meal
    adds no failure notice" (pins a Recipe, supersedes it, repeats
    `run_optimizer` until `no_progress`).
  - RED: failed at head with the unexpected notice
    "meal plan optimizer (fixed meal unavailable). This is a problem on our side".
  - GREEN: `session_bounds_test.exs` 37/37; full suite 1323 passed, 24 skipped;
    `mix precommit` passed. The existing optimizer-unavailable notice test
    still passes.
