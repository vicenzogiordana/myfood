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

- [ ] A Member can start a Planning Session over the channel; a second Member of the same Household is told one is already active
- [ ] Without recorded consent the session refuses to call the external provider
- [ ] With the scripted model, a session produces a Proposal event carrying a code-owned validity status
- [ ] An invalid optimizer result is never shown; its violations go back to the agent
- [ ] Optimizer failure produces a clear error to the agent and the Member, never a fallback plan
- [ ] The OpenAI adapter refuses to run when spend or token caps are unset, and reserves worst-case cost before each call
- [ ] Tool arguments naming another Household are ignored in favour of the session's Household
- [ ] Recipe and tool text is treated as data (a prompt-injection fixture does not change behaviour)
- [ ] Session-level tests run through the session module with scripted model and fakes; a few ChannelCase tests cover wiring

## Tasks

Delivery strategy: `single-pr` (the pipeline requests one PR per issue; forecast ~2000
authored lines, above the ~400 heuristic because the tracer bullet must land the full seam
with its tests at once; commits stay reviewable work units).

| ID | Task | Route | Status |
|----|------|-------|--------|
| T1 | Session module, model interface, scripted adapter, consent, household lock, context, limits | inline (bounded worker; no sub-delegation allowed) | pending |
| T2 | Tools: search_recipes, run_optimizer, present_proposal, ask_human; validator; injection and household-override tests | inline | pending |
| T3 | Port optimizer adapter over the port runner (no fallback), port-boundary tests with a fake script | inline | pending |
| T4 | OpenAI Responses adapter + spend ledger | inline | pending |
| T5 | Phoenix channel adapter, config, docs | inline | pending |

## Checks

- `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test_96 mix test test/meal_planner_api/planning_agent`
- `MIX_TEST_PARTITION=96 MYFOOD_TEST_DATABASE=meal_planner_api_test_96 mix test` and `mix precommit`

## Evidence

- `config/test.exs` does not append `MIX_TEST_PARTITION` to the DB name; isolation uses the
  existing `MYFOOD_TEST_DATABASE` override (`meal_planner_api_test_96`), no config change.
- Baseline before changes: 923 passed, 20 skipped.
