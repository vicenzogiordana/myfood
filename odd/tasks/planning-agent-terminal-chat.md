# Planning agent terminal chat (issue #168, PR #170)

Objective: `mix planning_agent.chat`, a terminal chat with the production
planning agent over a fictitious Household (spec #93).

Locator: `odd/tasks/planning-agent-terminal-chat.md`, branch
`feat/planning-agent-terminal-chat`.

## Review round 1 (Jorge el Curioso)

- [x] R1. `/quit`, `/confirm` or session end from standard input killed the
  chat process: the stdin reader is `spawn_link`ed and the `after` block
  kills it with `:kill`, so its `:killed` exit took the linked parent down
  before cleanup finished. Fix: `Process.unlink(reader)` before the kill
  (`chat/repl.ex`). Route: inline (one file plus one test).
  - RED: new test in `test/mix/tasks/planning_agent_chat_test.exs` runs the
    chat on `:stdio` under a group leader that answers `/quit` and then
    blocks; it failed with the chat process `DOWN ... :killed`.
  - GREEN: the test passes (5 repeated runs); manual PTY run of
    `mix planning_agent.chat --scripted` + `/quit` printed
    `Session spend: US$0.0000` and exited 0.
- [x] R2. `docs/PLANNING_CHAT.md` fixture description drifted: now 18
  recipes over 21 Ingredients priced by 23 products, pasta brands on
  spaghetti and penne, budget printed as `ARS 45000.00`; pantry (rice,
  onion, eggs) was already right. Proof: structural readback against
  `Household.spec()` (21 ingredients, 23 products, 18 recipes, 3 pantry
  items) and `Render.money(4_500_000)`. Exception to test-first: passive
  documentation, no runnable RED.

## User request in the same round

- [x] U1. Default Claude model is now `claude-haiku-5-5` (was
  `claude-opus-5-5`), with server-side refusal fallbacks off by default
  because Claude Haiku 5.5 rejects them; `PLANNING_AGENT_CLAUDE_FALLBACKS=true`
  turns them on for models that accept them. Files: `claude_messages.ex`,
  `config/runtime.exs` comment, `docs/QUALITY_BATTERY.md`, battery task doc.
  - RED: default tests in `claude_messages_test.exs` and
    `runtime_config_test.exs` asserted Haiku and fallbacks off and failed
    (3 failures).
  - GREEN: Opus-specific tests now pin `model: "claude-opus-5-5",
    fallbacks: true` explicitly (including `metered_model_test.exs`, which
    models the Opus battery prices).

## Checks

- `MYFOOD_TEST_DATABASE=meal_planner_api_test168 mix test`: 1412 passed,
  24 skipped.
- `mix precommit`: first run had 1 failing test that did not reproduce
  (failure output not captured); second run 1412 passed, 24 skipped.

## Next step

Push and comment on PR #170; Jorge re-review.
