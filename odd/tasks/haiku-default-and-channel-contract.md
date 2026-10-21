# Haiku Default and Exact Channel Contract

Issue: #169 — Part of spec #93.

## Objective

Make main ready for the frontend integration: the Claude adapter defaults to Claude Haiku 5.5
with refusal fallbacks off, and `docs/CHANNELS.md` describes the planning channel exactly as
the code implements it, guarded by a contract test.

## Problem / why

- The adapter defaulted to `claude-opus-5-5` with fallbacks on. The Haiku battery passed
  75/75 with 0 hard violations at about 1/24 of the Opus cost (#156), but Haiku 5.5 rejects
  the `fallbacks` parameter, so Haiku needs fallbacks off by default.
- The frontend must be able to implement the planning channel from the doc alone; drift
  between the doc and the emitted events must fail a test.

## Scope

- `ClaudeMessages` defaults: `model: "claude-haiku-5-5"`, `fallbacks: false`.
  `PLANNING_AGENT_CLAUDE_MODEL` and `PLANNING_AGENT_CLAUDE_FALLBACKS=true` still override.
- Docs and comments that name the default model (runtime.exs, QUALITY_BATTERY.md,
  CHANNELS.md, the adapter moduledoc, the battery task doc).
- CHANNELS.md audit against the code: client events, pushes, every `agent_event` type and its
  fields, Proposal fields, error/refusal reasons, the session lifecycle.
- A contract test asserting the documented `agent_event` types (and fields where practical)
  against the session's allowlist.

Out of scope: behavior changes to the channel itself (only doc fixes unless a real bug blocks
the contract).

## Tasks

- [x] T1 Haiku default with fallbacks off; overrides keep Opus and fallbacks working; tests
      and docs. Route: inline (one adapter module, one config, known tests).
- [ ] T2 CHANNELS.md audited against the code plus a contract test for documented event types
      and fields. Route: inline (single doc plus one test; the bounded worker does not spawn
      subagents).

## Acceptance criteria

- With no env override, the adapter runs Haiku with fallbacks off. With overrides, Opus and
  fallbacks work as before. Covered by tests.
- CHANNELS.md matches the code, and the contract test passes.
- `mix precommit` passes.

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test169 mix test`
- `MYFOOD_TEST_DATABASE=meal_planner_api_test169 mix precommit`

## Progress

- T1: done. RED observed (3 failures: default model and fallbacks), GREEN after the default
  change; fixtures that exercise the fallback path now set `fallbacks: true` explicitly.
  Full suite: 1411 passed, 24 skipped.
- T2: pending

## Next step

T2.
