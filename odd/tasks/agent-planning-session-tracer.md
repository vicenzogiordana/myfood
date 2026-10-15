# Agent Planning Session tracer bullet

Issue: #96 — Part of spec #93 (user stories 1–3, 5, 6, 10, 11, 18, 61–64, 81, 96, 98–106).

## Objective

A Member opens a Planning Session for a Planning Range of unplanned days and, by talking
to the culinary agent, receives a validated Proposal. This lands the channel-agnostic
planning agent session module (the main test seam) with a thin Phoenix channel adapter
beside the legacy flow.

## Problem / why

The legacy planning chat parses requests with regular expressions, runs generation in a
non-cancellable in-memory process and silently falls back to a greedy plan when the
optimizer fails. The spec replaces it with a bounded agent whose validity always comes
from code. This tracer bullet proves the full path end to end with the smallest tool set.

## Scope

- `MealPlannerApi.PlanningAgent.Session`: one supervised process per Planning Session,
  owning the loop, limits (5 min, 10 iterations), consent gate, workspace and events.
- `MealPlannerApi.PlanningAgent.Model` behaviour (`init/1`, `respond/2`) with a scripted
  adapter and an OpenAI Responses adapter (`gpt-6.1-sol`, one provider, no failover).
- `MealPlannerApi.PlanningAgent.SpendLedger`: mandatory spend and token caps, worst-case
  reservation before each paid call, settlement after.
- `MealPlannerApi.PlanningAgent.Consent` + `ai_processing_consents` table.
- `MealPlannerApi.PlanningAgent.HouseholdContext`: profile, settings and consent injected
  by code at start (Restrictions summarised generically, never by Member).
- Tools: `search_recipes`, `run_optimizer`, `present_proposal`, `ask_human`.
- `MealPlannerApi.PlanningAgent.Optimizer.Port`: the existing Python optimizer through the
  port runner, one subprocess per call, typed errors, no greedy fallback.
- One Planning Session per Household via the existing `planning_sessions` table, guarded by
  a transaction-scoped advisory lock (legacy overlap EXCLUDE stays in place).
- `MealPlannerApiWeb.PlanningAgentChannel` on `planning_agent:<household_id>`.

Out of scope (later issues of #93): purchase calculation and budget deviations
(`requires_approval`), grace/recovery, Stop, confirmation, the remaining tools, optimizer
contract changes (variety, pins, relaxation). Numeric spend/token caps are a human decision.

## Constraints

- Household always comes from the session, never from model arguments.
- Recipe and tool text is data: tool results travel only as tool-result messages; the
  instructions are built by code and never include tool output.
- Paid execution impossible unless spend and token caps are configured.
- Tests: fictitious fixtures, through public interfaces, scripted model and fakes.

## Acceptance criteria

- [x] A Member can start a Planning Session over the channel; a second Member of the same Household is told one is already active
- [x] Without recorded consent the session refuses to call the external provider
- [x] With the scripted model, a session produces a Proposal event carrying a code-owned validity status
- [x] An invalid optimizer result is never shown; its violations go back to the agent
- [x] Optimizer failure produces a clear error to the agent and the Member, never a fallback plan
- [x] The OpenAI adapter refuses to run when spend or token caps are unset, and reserves worst-case cost before each call
- [x] Tool arguments naming another Household are ignored in favour of the session's Household
- [x] Recipe and tool text is treated as data (a prompt-injection fixture does not change behaviour)
- [x] Session-level tests run through the session module with scripted model and fakes; a few ChannelCase tests cover wiring

## Tasks

Delivery strategy: `single-pr` (the pipeline requests one PR per issue; forecast ~2000
authored lines, actual 3734 added lines including tests and docs, above the ~400 heuristic because the tracer bullet must land the full seam
with its tests at once; commits stay reviewable work units).

| ID | Task | Route | Status |
|----|------|-------|--------|
| T1 | Session module, model interface, scripted adapter, consent, household lock, context, limits | inline (bounded worker; no sub-delegation allowed) | done (`49cc275`) |
| T2 | Tools: search_recipes, run_optimizer, present_proposal, ask_human; validator; injection and household-override tests | inline | done (`2095ee2`) |
| T3 | Port optimizer adapter over the port runner (no fallback), port-boundary tests with a fake script | inline | done (`23542aa, 086808b`) |
| T4 | OpenAI Responses adapter + spend ledger | inline | done (`49a307b`) |
| T5 | Phoenix channel adapter, config, docs | inline | done (`f35cb9b`) |
| R1 | Jorge round 1 (PR #114): ledger survives killed turns, unknown usage settles at the reservation, refused cancel still expires | inline | done (see Review round 1) |
| R2 | Jorge round 2 (PR #114): bound Member message size; stop claiming code enforces budget and Nutrition Goal | inline | done (see Review round 2) |
| R3 | Jorge round 3 (PR #114): reap the optimizer when the turn is brutally killed; drop the draft on failed re-runs; 14-digit consent migration version | inline | done (see Review round 3) |
| R4 | Jorge round 4 (PR #114): trap exits so shutdown releases the lock; stop a Session whose lease renewal finds its row expired | inline | done (see Review round 4) |
| R5 | Jorge round 5 (PR #114): keep the provider API key out of status output and crash reports; align channel error replies with the documented contract | inline | done (see Review round 5) |
| R6 | Jorge round 6 (PR #114): refuse incomplete or empty provider responses; refuse non-map start_session payloads with invalid_payload | inline | done (see Review round 6) |
| R7 | Jorge round 7 (PR #114): catch exits from cancel_session when the session dies between lookup and call | inline | done (see Review round 7) |

## Checks

- `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test_96 mix test test/meal_planner_api/planning_agent`
- `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test_96 mix test` and `mix precommit`

## Evidence

- `config/test.exs` does not append `MIX_TEST_PARTITION` to the DB name; isolation uses the
  existing `MYFOOD_TEST_DATABASE` override (`meal_planner_api_test_96`), no config change.
- Baseline before changes: 923 passed, 20 skipped.
- T1 RED: `session_test.exs` 0/14 (`Session.start/2` undefined); GREEN 14/14.
- T2 RED: `session_tools_test.exs` 1/13 (only the unknown-tool case passed); GREEN 14/14
  after splitting the name/ingredient search case into two sessions.
- T3 RED: `optimizer/port_test.exs` 0/6 (module missing); GREEN 6/6 against
  `test/support/fixtures/fake_optimizer.py` (python3 stand-in; real OR-Tools not installed locally).
- T4 RED: `model/openai_responses_test.exs` 0/9; GREEN 9/9 (Req.Test stub, no network).
- T5 RED: `planning_agent_channel_test.exs` failed (channel module missing); GREEN 5/5.
- Full suite (`MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test_96 mix precommit`):
  exit 0, 971 passed, 20 skipped. Remaining compiler warnings are pre-existing in unrelated test files.

## Review round 1 (Jorge el Curioso, PR #114)

Confirmed findings and fixes (each RED first, then GREEN):

1. Spend ledger lost when a turn is killed or crashes (medium). The model request now
   carries an optional `checkpoint` callback; the OpenAI adapter reports its reserved state
   before the paid call, the loop reports every returned model state, and the Session adopts
   checkpoints (draining queued ones after `Task.shutdown/2`). RED: `session_test.exs`
   "spend reserved by a turn killed at the deadline stays counted" got `limit_reached` twice
   instead of `spend_cap_reached`; `openai_responses_test.exs` checkpoint test got no message.
2. A 200 response with missing or invalid usage settled at zero (low). Unknown usage now keeps
   the reservation as spent, like the error branch. RED: spent 0 vs >= 4_000 for both the
   no-usage and string-token cases.
3. A refused `cancel_session` cleared `session_id`, so `terminate/2` skipped
   `expire_session` (low). The id is now kept on error. RED: row stayed `:active`.

Checks: `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test96 mix test`
976 passed, 20 skipped; `mix precommit` exit 0, 976 passed, 20 skipped.

## Review round 2 (Jorge el Curioso, PR #114)

Confirmed findings and fixes (each RED first, then GREEN):

1. SP-1: `send_message` text had no size bound (medium). `Session` now refuses texts over
   `max_message_bytes/0` (4_000 bytes) with `{:error, :message_too_long}` before consent
   and turn checks, so nothing is stored or sent to the model; the channel replies
   `%{reason: "message_too_long"}`. RED: `session_test.exs` and
   `planning_agent_channel_test.exs` failed with `max_message_bytes/0` undefined.
2. CD-2: instructions claimed the budget and Nutrition Goal were "enforced by code" (medium).
   Only Restrictions and allergies stay under that heading; disliked ingredients move under
   "Household preferences (not enforced by code)"; the budget and Nutrition Goal move under
   "Targets, not yet validated by code (tell the household they are unchecked)" with a rule
   never to claim a plan meets them. Optimizer and validator behaviour unchanged. RED:
   new `household_context_test.exs` 0/2; GREEN 2/2.

Checks: focused files 21/25 RED then 25/25 GREEN;
`MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test96 mix test` 980 passed,
20 skipped; `mix precommit` exit 0, 980 passed, 20 skipped.

## Review round 3 (Jorge el Curioso, PR #114)

Confirmed findings and fixes:

1. TR-1: a brutally killed turn orphaned the Python optimizer (medium). `Optimizer.Port.solve/2`
   now starts a reaper process that monitors the caller and runs `kill -9` on the OS pid if
   the caller dies before the call finishes (`:brutal_kill` skips the `after` block). RED:
   new `port_test.exs` case "a brutally killed caller does not orphan the optimizer process"
   (hang fixture, `Task.shutdown(:brutal_kill)`, `kill -0` still succeeded) 6/7; GREEN 7/7.
2. CD-3: `present_proposal` could show a stale draft after a failed `run_optimizer`
   (low). The `no_candidates` and `search_failed` branches now reset `draft: nil`, like the
   optimizer-error branch. RED: new `session_tools_test.exs` case got a `valid` proposal
   instead of `no_plan_to_present` (14/15); GREEN 15/15.
3. CD-1: the consent migration had a 15-digit version that sorted after every future
   14-digit migration (low). Renamed to `20261015120000_create_ai_processing_consents.exs`,
   contents unchanged. No runnable RED (ordering only); structural check: test DB dropped,
   created and migrated from scratch (33 migrated), `mix ecto.migrations` lists it `up`
   after `20261014120000_create_ingredient_tags`. The merged #95 15-digit migration is a
   pre-existing follow-up, untouched.

Checks: `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test96 mix test`
982 passed, 20 skipped; `mix precommit` exit 0, 982 passed, 20 skipped.

## Review round 4 (Jorge el Curioso, PR #114)

Route: inline (one source file and its test). Confirmed findings and fixes:

1. Session did not trap exits, so a `:shutdown` from the DynamicSupervisor or Application
   skipped `terminate/2` and left the `planning_sessions` row `:active` until the lease
   lapsed (low). `init/1` now sets `Process.flag(:trap_exit, true)`; turns run under
   `Task.Supervisor.async_nolink`, so no turn `:EXIT` reaches the Session. RED: new
   `session_test.exs` case "a supervisor shutdown releases the Household lock"
   (`DynamicSupervisor.terminate_child`) never received `session_ended` (17/19 with the
   case below); GREEN.
2. `handle_info(:renew_lease)` discarded `{:error, :not_active}` and kept running and
   spending after its row was expired (low). The Session now stops the turn, emits
   `session_ended` and stops `:normal` with `session_id: nil`, so `terminate/2` does not
   call `expire_session` again. RED: new case "a session whose lock row was expired stops
   on lease renewal" (`PlanningRepo.expire_session` + `send(pid, :renew_lease)`) got no
   `:DOWN`; GREEN 19/19 (three consecutive runs).

Checks: `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test96 mix test`
984 passed, 20 skipped; `mix precommit` exit 0, 984 passed, 20 skipped.
`config/test.exs` does not append `MIX_TEST_PARTITION` to the DB name, so isolation relies
on `MYFOOD_TEST_DATABASE`.

## Review round 5 (Jorge el Curioso, PR #114)

Route: inline (two source files, their tests and `docs/CHANNELS.md`; each fix is small and
already understood). Confirmed findings and fixes:

1. SP-1 (medium): the OpenAI API key (`model_state.config.api_key`) and the Household chat
   lived in the Session state with no redaction, and OTP prints that state in
   `:sys.get_status/1` and crash reports. The Session now stores the model state sealed in a
   closure (`seal/1`, inspected as `#Function<...>`) from `start/2` onward, including
   checkpoints and the turn result; only the turn process unseals it before calling the
   model. A `format_status/1` callback reduces the chat to its length and a Member message
   to a marker. Plain `format_status/1` redaction was not enough: OTP 29 appends the raw
   stacktrace, whose `handle_call/3` frame carries the full state, outside the callback.
   The model behaviour and the spend ledger are unchanged. RED: new `session_test.exs`
   cases "the provider API key is absent from the session's status output" and "... from a
   crashed session's report" (forced `FunctionClauseError`, logger translator at
   `limit: :infinity`) both printed `sk-test-secret`; GREEN.
2. CD-3 (low): `send_message` without a binary `text` fell to the catch-all and replied
   `invalid_payload`, and every non-atom error became `invalid_payload`. `send_message` now
   always reaches the Session, which replies `invalid_message`; non-atom reasons reply
   `internal_error`. `docs/CHANNELS.md` now lists `invalid_message`, `message_too_long`,
   `overlapping_range`, `pricing_unconfigured`, `provider_unconfigured`, `internal_error`
   and the catch-all `invalid_payload`. RED: new channel cases "a message without text is
   refused with invalid_message" and "a non-atom failure is replied as internal_error"
   both got `invalid_payload`; GREEN. The overlapping-range case passed before the fix: the
   Household lock check runs first, so an overlap is reported as `session_already_active`,
   which the docs now state (`overlapping_range` stays the store's last-resort guard).

Checks: `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test96 mix test`
989 passed, 20 skipped; `mix precommit` exit 0, 989 passed, 20 skipped.

## Review round 6 (Jorge el Curioso, PR #114)

Route: inline (two source files and their tests; each fix is small and already understood).
Confirmed findings and fixes:

1. Medium: `OpenAIResponses.parse/1` ignored `status` and returned `{:ok, nil, []}` for a 200
   response with neither a message nor a tool call, so the Loop emitted an empty assistant
   message and completed the turn. `parse/1` now returns `:error` (replied as
   `{:error, :invalid_provider_response, state}`) when `status` is `"incomplete"` or when the
   output has no text and no tool call. Loop, Session and spend semantics are unchanged.
   RED: new `openai_responses_test.exs` cases "a 200 response with neither a message nor a
   tool call ..." (reasoning-only output) and "an incomplete 200 response ..." (partial
   text, `max_output_tokens`) both got `{:ok, ...}`; GREEN.
2. Low: `handle_in("start_session", ...)` had no `is_map/1` guard, so a string or list
   payload raised `BadMapError` and killed the channel. The clause is now guarded and a
   non-map payload reaches the `invalid_payload` catch-all. RED: new channel case "a non-map
   start_session payload is refused with invalid_payload and the channel survives" crashed
   with `BadMapError`; GREEN.

Checks: `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test96 mix test`
992 passed, 20 skipped; `mix precommit` exit 0, 992 passed, 20 skipped.

## Review round 7 (Jorge el Curioso, PR #114)

Route: inline (one channel clause and one test; the fix mirrors the existing
`with_own_session/2` exit handling).
Confirmed finding and fix:

1. Low: `handle_in("cancel_session", ...)` called `Session.cancel/2` after
   `Session.whereis/1` with no exit handling, so a session that died between the lookup and
   the call (or a 5 s call timeout) crashed the channel. The clause now catches `:exit`,
   replies `{:error, %{reason: "no_active_session"}}` and clears `session_pid`. Session
   internals and the other handlers are unchanged. RED: new channel case "cancelling a
   session that dies before replying keeps the channel alive" (a Registry-held stub that
   exits on the call) failed with `EXIT ... GenServer.call(..., {:cancel, ...}) ** (EXIT)
   shutdown`; GREEN.

Checks: `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test96 mix test`
993 passed, 20 skipped; `mix precommit` exit 0, 993 passed, 20 skipped.

## Known limits handed to later slices of #93

- Purchase calculation and budget deviations (`requires_approval`), Nutrition Goal in the
  optimizer, variety, pins and relaxation: candidates enter with zero cost and wide bounds.
- Grace and recovery: the session ends when its last subscriber leaves.
- Stop (a cancelled or timed-out turn now force-kills its optimizer subprocess).
- Numeric spend and token caps and prices: unset by default (human decision).

## Next step

Re-run the Jorge review gate on PR #114 after review round 7.
