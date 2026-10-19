# Claude model adapter for the planning agent

Issue: #141 — Part of spec #93.

## Objective

Anthropic's Claude can be the production model provider behind the provider-neutral
`MealPlannerApi.PlanningAgent.Model` behaviour. `Model.ClaudeMessages` speaks the
Messages API (`POST /v1/messages`) over raw HTTP with `Req`. The planning loop, tools
and Session do not change.

## Problem / why

Only the OpenAI Responses adapter exists. The product prefers Claude as the provider,
so the agent needs a second adapter with the same spend guarantees, selectable by
environment in the runtime config and in `mix planning_agent.battery`.

## Scope

- `Model.ClaudeMessages`: `init/1`, `respond/2`, `recoverable/1`, `recover/2`, `spend/1`.
- Model `claude-opus-5-5` by default (`PLANNING_AGENT_CLAUDE_MODEL`); adaptive thinking
  with explicit `output_config.effort` (default `medium`, `PLANNING_AGENT_CLAUDE_EFFORT`);
  `tool_choice: auto`; no `budget_tokens`, sampling parameters or prefill.
- Neutral tools, tool calls and tool results map to Claude tools, `tool_use` and
  `tool_result` blocks; all tool results of one turn in one user message.
- Preserved thinking: the exact assistant content blocks are kept in the adapter state,
  keyed by the position and identity of the neutral messages they produced, and resent
  unchanged; they survive `recoverable/1` / `recover/2` (no credentials stored).
- Spend: mandatory caps and prices, worst-case reservation (with the `checkpoint`
  callback) before each call, settlement from `usage` including cache read / write
  tokens and every `usage.iterations` attempt (server-side fallback).
- Prompt caching: explicit breakpoint on the instructions (caches tools + system) plus
  automatic caching of the conversation tail.
- Stop reasons: `refusal` → `:provider_refused`, `max_tokens` →
  `:provider_output_truncated`, `model_context_window_exceeded` →
  `:provider_context_exceeded`, others not finished → `:invalid_provider_response`.
- Server-side fallback `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`).
  A fallback attempt is identified by a `usage.iterations` entry of `type:
  "fallback_message"` and priced at the configured fallback prices; every other
  iteration, and the top-level `usage` when `iterations` is absent, at the primary
  prices. The `model` string is never read for pricing.
- `PLANNING_AGENT_MODEL_PROVIDER=openai|claude` in `config/runtime.exs` and in the battery
  command; docs list the Claude variables.

Out of scope: streaming, per-message effort, mid-conversation tool changes, real API calls.

## Constraints

- No real Anthropic call: tests use `Req.Test` stubs with fictitious fixtures.
- Request shapes follow the bundled Claude API reference (curl examples, tool use,
  prompt caching, Opus 5.5 migration, refusals and fallback docs).
- Spend never under-reserved for the first attempt plus the configured number of
  fallback attempts; unknown usage keeps the worst case spent.

## Tasks

- [x] T1 Shared paid-call helpers extracted from the OpenAI adapter (route: inline, one module + mechanical edit). Commit a57995b; OpenAI adapter tests 33/33 green before and after (refactor, no RED).
- [x] T2 `Model.ClaudeMessages` adapter with contract tests (route: inline; single writer, this worker). Commit 0993683; RED 0/41 (module missing), GREEN 41/41.
- [x] T2b Settled fallback pricing contract after review (route: inline; one module and its test file). Served-by signal is the iteration `type`, never the `model` string; cache-read price joins the worst case (CD-2); recovery row deletion on Session end confirmed (CD-3, no Session change). RED 6 failing, GREEN 47/47; `mix precommit` 1444 passed, 25 skipped. Commit d4f38a8.
- [ ] T3 Provider selection in `config/runtime.exs` and the battery command, docs (route: inline). Implemented as commit 22d1095 on the stacked branch `feat/issue-141-provider-selection` (RED 7 failing, GREEN 22/22); split out of this PR because the adapter and its tests alone are ~1,240 authored lines, over the ~800-line PR budget.

## Acceptance criteria

- [x] Adapter implements the Model behaviour and passes the same contract tests as the OpenAI adapter (Req stub).
- [x] Tool calls round-trip as `tool_use` / `tool_result` blocks, results in one user message.
- [x] Assistant content blocks (including thinking) are resent unchanged and survive recover.
- [x] Init refuses without caps or prices; spend reserved before and settled after each call, including cache tokens.
- [x] Refusal and max_tokens stop reasons yield typed errors.
- [ ] (stacked branch) Provider selectable by env in runtime config and battery; QUALITY_BATTERY.md and CHANNELS.md list the Claude variables.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test141 mix test`
- `MYFOOD_TEST_DATABASE=meal_planner_api_test141 mix precommit`

## Progress

- Delivery strategy: chained. PR 1 = T1 + T2 (adapter slice); T3 on the stacked
  branch `feat/issue-141-provider-selection`, to open after PR 1 merges.
- Checks on the adapter slice: `mix precommit` 1438 passed, 25 skipped. One earlier
  full run on the T3 branch had 3 failures alongside Postgrex disconnect logs; two
  reruns passed 1443/1443 (flaky, not reproduced).
- Decisions: fallback prices are mandatory while fallbacks are on (the fallback model
  can cost more than the requested one); the worst case reserves the call plus
  `max_fallback_attempts` (default 1) fallback attempts; cache prices default to
  1.25x / 1x input. No `thinking.block_binding` is sent: its acceptance by fallback
  models is undocumented, so instructions and tools must stay byte-stable.
- Review rework (Jorge, verified API contract): fallback detection moved from comparing
  the response `model` to `config.model` (wrong for dated variants, aliases and absent
  names) to the `fallback_message` iteration type. A `fallback_message` while fallbacks
  are off has no price and keeps the worst case spent. The worst case now uses the
  highest of input, cache-write and cache-read prices. `assistant_turns` is not pruned
  (CD-3); its `planning_agent_recoveries` row is deleted on confirm, cancel, expiry and
  lost lock (existing tests in `session_recovery_test.exs`).
- Review round 2 (Jorge, medium, verified at 4f8d193): the default `receive_timeout_ms`
  (120 s) exceeded the default `:model` attempt deadline of `CallBounds` (60 s), so the
  HTTP timeout never fired and slow turns were brutal-killed with an open reservation.
  Fix: default lowered to 55 s, and when a request carries `:timeout_ms` the receive
  timeout is capped below it (margin `min(1 s, timeout/5)`), so the call fails as a
  settled `:provider_timeout`. RED: 2 failing tests (default above deadline; a real
  Bandit server answering after the deadline returned `{:error, :timeout, _}`). GREEN:
  adapter suite 49/49 (3 repeated runs), `mix precommit` 1446 passed, 25 skipped (one
  earlier run hit the pre-existing timing flake `session_bounds_test.exs:123`, 59 < 60 ms,
  passing 3/3 in isolation on the base). Residual: the planning loop does not pass
  `call.timeout_ms` to `respond/2` yet (Loop out of scope), so in production only the
  55 s default applies; a model needing longer turns must raise `receive_timeout_ms` and
  the `:model` call policy together (provider-selection slice).
- Review round 3 (Jorge, medium, CD-1 + TR-1, verified at 8c9b470): that residual made
  the round-2 cap dead code. `Loop.call_model` never put `call.timeout_ms` in the
  request, so with less than 55 s of global time left, or with a lowered `:model` policy,
  the attempt was still brutal-killed mid-POST with its reservation open. Fix: the loop
  now passes `call.timeout_ms` to `respond/2`, and `Model.request` gains
  `optional(:timeout_ms)` (adapters ignore unknown keys). Route: inline (2 small files
  plus one test). RED: a `Loop.run` test (real Bandit slow server, `:model` policy
  1000 ms, default 55 s receive timeout, no hand-built request) returned
  `reserved_micros: 41915`. GREEN: adapter suite 50/50; `mix test` and
  `mix precommit` both 1447 passed, 25 skipped.
- Review round 4 (Jorge, low, verified at 14af808): when the global deadline bounded a
  `:model` attempt, the adapter's receive-timeout margin returned `:provider_timeout`
  before the attempt deadline, so `CallBounds` treated it as transient (an extra paid
  call could start with ~400 ms) and the turn ended `{:failed, :provider_timeout}`
  instead of `{:limit_reached, "time"}`. Fix: `CallBounds.attempt` maps a
  `:provider_timeout` from a globally bounded attempt to `:deadline_exceeded` when the
  time left is within that margin (`min(1 s, timeout/5)`); a quick provider timeout with
  time left is still retried. Retry policy, margin, adapters unchanged. Route: inline
  (1 lib file, 2 tests). RED: a `CallBounds` test (`:provider_timeout` after 80 % of a
  500 ms global window) returned `:provider_timeout`; a `Loop.run` test (real Bandit slow
  server, 2 s global deadline, default 60 s policy) ended `{:failed, :provider_timeout}`.
  GREEN: one POST, reservation settled, outcome `{:limit_reached, "time"}`; `mix test` and
  `mix precommit` both 1450 passed, 25 skipped.
- Mirror: Engram topic `odd/claude-model-adapter/tasks`.
- Next step: merge PR 1, then open the PR for `feat/issue-141-provider-selection`.
