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
- Server-side fallback `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`),
  fallback attempts priced at the configured fallback prices.
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

- [ ] T1 Shared paid-call helpers extracted from the OpenAI adapter (route: inline, one module + mechanical edit).
- [ ] T2 `Model.ClaudeMessages` adapter with contract tests (route: inline; single writer, this worker).
- [ ] T3 Provider selection in `config/runtime.exs` and the battery command, docs (route: inline).

## Acceptance criteria

- [ ] Adapter implements the Model behaviour and passes the same contract tests as the OpenAI adapter (Req stub).
- [ ] Tool calls round-trip as `tool_use` / `tool_result` blocks, results in one user message.
- [ ] Assistant content blocks (including thinking) are resent unchanged and survive recover.
- [ ] Init refuses without caps or prices; spend reserved before and settled after each call, including cache tokens.
- [ ] Refusal and max_tokens stop reasons yield typed errors.
- [ ] Provider selectable by env in runtime config and battery; QUALITY_BATTERY.md and CHANNELS.md list the Claude variables.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test141 mix test`
- `MYFOOD_TEST_DATABASE=meal_planner_api_test141 mix precommit`

## Progress

- Delivery strategy: single PR (forecast ~800 authored lines incl. tests).
