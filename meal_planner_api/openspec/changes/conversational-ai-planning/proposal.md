# Proposal: Conversational AI Meal Planning

> **Owner sub-project**: `meal_planner_api`. Artifacts under
> `meal_planner_api/openspec/changes/conversational-ai-planning/`.
> **Status**: `proposed`
> **Related context**: `meal_planner_api/ARCHITECTURE.md` (external integrations:
> `optimizer` Port, `ai` Gemini behaviour); parallel branch
> `fix/planning-pipeline-plumbing` (treated as a merged prerequisite — see
> Dependencies).

## Intent

Today, "chat" in the planning flow is not AI. `GenerationService.parse_modification/1`
is a regex matcher recognizing ~3 fixed patterns ("cheaper", "more protein",
"remove X"); free text is never parsed into constraints, and there is no LLM
anywhere in `PlanningChannel` → `Generation.Server` → `PayloadAdapter` →
`OptimizerServer` (verified by direct read of `generation_service.ex`,
`generation/server.ex`, `planning_channel.ex`). Meanwhile `MealPlannerApi.AI`
already wraps a working `GeminiClient`/`MockClient` (`generate_text/2`,
streaming via `AIChannel`) for the cooking assistant.

The product goal is a genuinely versatile planning dialogue: the user
negotiates budget, dates, dietary needs, and per-day/per-slot guest counts
("Sunday we cook for 10, rest of the week for 4") in free text until they
like the proposal, then confirms once — the calendar and shopping list are
built from that single decision. This proposal wires an LLM into both ends of
the existing solver pipeline (constraint extraction in, narration out) and
adds the variable-servings support the servings negotiation requires, which
has zero support today: `ScheduledMeal` has no `servings` field (confirmed:
`scheduled_meal.ex` schema/changeset), shopping quantities copy
`quantity_milli` raw with no multiplication (confirmed:
`shopping_repo.ex` `upsert_shopping_item/1`), and `Recipe.servings` exists but
is inert.

## Scope

### In Scope

1. **LLM constraint extraction** — free-text/speech chat message → structured
   constraint delta via Gemini, merged into the session's running constraint
   set, changeset-validated before it ever reaches the solver.
2. **LLM narration** — after the solver returns a plan, a second LLM turn
   narrates it conversationally, referencing the user's own context (guest
   counts, budget). Narration never mutates recipe IDs, quantities, or prices.
3. **Variable servings end-to-end** — `ScheduledMeal.servings`,
   `proposal_json` slot shape, optimizer payload + `optimizador.py` cost/macro
   scaling, shopping-item quantity scaling, cooking-completion inventory
   deduction scaling.
4. **Conversation state decision** — whether chat turns need a persisted
   table (`planning_chat_messages`) or remain in-memory
   (`Generation.Server` state + `planning_generation_runs.input_context`).

### Out of Scope

- Web scraping of prices, online purchase integration (Fase 2 per PRD).
- Frontend / React Native work.
- The 4 plumbing fixes on `fix/planning-pipeline-plumbing` (empty candidates
  bug, optimizer config, non-atomic confirm, eager shopping-list-at-confirm)
  — treated as **done prerequisites**, not re-scoped here.
- Admin/analytics visibility into chat content.

## Capabilities (contract with `sdd-spec`)

No `openspec/specs/` directory exists yet in this repo — every capability
below is a first spec, not a delta.

### New Capabilities

- `conversational-constraint-extraction` — chat message (text or speech
  transcript) → structured constraint delta (budget, date range, macro
  bounds, exclusions, favorites, per-date/slot servings overrides); merged
  into the session's running constraint set; rejected before the solver if
  invalid/out-of-range/hallucinated.
- `plan-narration` — post-solve LLM turn presenting the proposal
  conversationally; read-only over the solved plan, never a write path.
- `variable-servings` — per-slot requested servings flowing through
  `ScheduledMeal`, `proposal_json`, the optimizer payload, `optimizador.py`,
  shopping-item quantities, and cooking-completion inventory deduction.
- `planning-chat-history` — **tentative**, gated on Open Question 4 below;
  persistence of chat turns (`content_type: text | speech_transcript`) for
  session continuity and LLM context window.

### Modified Capabilities

None — this proposal establishes the baseline specs for the AI-planning
domain; no pre-existing spec is being changed.

## Approach

**1. Constraint extraction** replaces the call site in
`Generation.Server.handle_chat/3` (currently `GenerationService.parse_modification/1`).
`MealPlannerApi.AI` gains a schema-constrained extraction path (Gemini
`responseMimeType: application/json` + `responseSchema`, or a strict
JSON-mode system prompt if the pinned model lacks native schema support —
`sdd-design` to confirm against `gemini-2.5-flash-lite`), reusing the same
`GeminiClient`/`MockClient` behaviour pair and env-based client selection
already used by `generate_text/2`. The LLM output is a **constraint delta**
only — never a recipe ID, price, or solver decision. Each delta merges into
the account's running constraint set (held today in `Generation.Server`
GenServer state, same shape as `planning_generation_runs.input_context`) and
passes a `ConstraintDelta` changeset (budget/macro bounds, date range inside
the requested week, servings `> 0` and `<= cap`) before touching
`PayloadAdapter`/`OptimizerServer`. Invalid or hallucinated extractions
(invented recipe references, ingredients outside the catalog, out-of-range
values) are rejected pre-solver and narrated back as a clarification request
— the LLM proposes, the changeset and the solver decide.
`GenerationService.parse_modification/1` is kept as a **circuit-breaker
fallback** when the LLM client errors or the circuit is open, mirroring the
existing `OptimizerServer` circuit-breaker pattern.

**2. Narration** runs after `proposal_json` is persisted: a second
`generate_text`-style call receives only deterministic, already-solved data
(slots, prices, macros) plus the accumulated constraint context (dates,
servings overrides, budget) and returns narration text. `PlanningChannel`'s
`proposal_ready`/`proposal_update` payloads gain a `narration` field;
streaming reuses `AIChannel`/`GeminiClient`'s SSE plumbing.

**3. Variable servings**: add `servings` to `scheduled_meals`; add
`requested_servings` to each `proposal_json` slot and to the optimizer
payload built by `PayloadAdapter`. `optimizador.py` must scale each
candidate's cost and macros by `requested_servings / recipe.servings` before
optimizing — `sdd-design` must read `optimizador.py`'s candidate model
line-by-line first (not reviewed in this proposal pass; flagged as a design
prerequisite, not assumed). `ShoppingRepo.upsert_shopping_item/1` must scale
`quantity_milli` by the same factor instead of copying it raw; the same
factor applies to cooking-completion inventory deduction. **Default servings
source is an open product question** (see below) — likely candidates are
active `AccountMembership` count or `Account.plan` family size, but this is
explicitly deferred to owner decision before design.

**4. Conversation state**: (a) keep ephemeral in `Generation.Server` state,
snapshot the final merged constraint set into `input_context` on confirm — no
new table, but no LLM context survives a reconnect/app restart; or (b) a new
`planning_chat_messages` table (`generation_run_id`, `role`, `content`,
`content_type: text | speech_transcript`, timestamps) for durability, audit
trail, and a real multi-turn context window. Recommended default: (b),
because "iterate until you like it" implies the user may background the app
mid-negotiation — but this is a proposal-question item, not a unilateral
decision.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `lib/meal_planner_api/generation/server.ex` | Modified | `handle_chat/3` calls LLM extraction instead of (or before falling back to) `parse_modification/1` |
| `lib/meal_planner_api/services/generation_service.ex` | Modified | `parse_modification/1` kept as fallback; new `ConstraintDelta` validation helpers |
| `lib/meal_planner_api/ai.ex`, `lib/meal_planner_api/ai/gemini_client.ex`, `.../mock_client.ex` | Modified | New structured-extraction + narration entry points, same client-selection pattern |
| `lib/meal_planner_api_web/channels/planning_channel.ex` | Modified | `proposal_ready`/`proposal_update` payload gains `narration`; `chat` handler unchanged at the wire level |
| `lib/meal_planner_api/persistence/planning/scheduled_meal.ex` | Modified | New `servings` field + changeset cast/validation |
| `lib/meal_planner_api/optimization/payload_adapter.ex`, `optimizer_server.ex` | Modified | Per-slot `requested_servings` in the payload contract |
| `optimizador.py` | Modified | Scale candidate cost/macros by `requested_servings / recipe.servings` |
| `lib/meal_planner_api/data/shopping_repo.ex` | Modified | `upsert_shopping_item/1` scales `quantity_milli`, not raw copy |
| `lib/meal_planner_api/services/cooking_service.ex` | Modified | Inventory deduction scaled by servings factor |
| `priv/repo/migrations/` | New | `servings` column; optional `planning_chat_messages` table |
| `lib/meal_planner_api/persistence/planning/` | New (conditional) | `planning_chat_message.ex` schema, gated on Open Question 4 |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **LLM cost/latency** — every chat turn now costs a Gemini call, and possibly two per generate cycle (extraction + narration) | High | Circuit-breaker fallback to `parse_modification/1` on error/timeout (mirrors `OptimizerServer`); cap `maxOutputTokens`; consider debouncing rapid successive chat messages before re-invoking the solver |
| **Prompt injection** — user free text reaches an LLM that emits structured params which flow toward the solver | High | LLM output is constraints-only, never recipe IDs/prices; every extraction passes a `ConstraintDelta` changeset (bounds, enum values, existing recipe/ingredient IDs only) before the solver sees it; reject-and-clarify on any validation failure |
| **Hallucinated extraction** (invented ingredient, out-of-range servings, wrong date) | Medium | Same changeset gate; servings capped (`sdd-design` to size the cap); date range constrained to the requested week |
| **`optimizador.py` scaling correctness** — cost/macro scaling bugs silently produce wrong budgets | Medium | Design phase reads the candidate-generation code before writing the formula; property tests across servings 1–20 |
| **Regression of the existing 3-pattern chat UX** during rollout | Low | Fallback parser kept, not deleted; feature-flagged LLM extraction |
| **Chat/speech content sensitivity** if `planning_chat_messages` ships | Medium | Retention policy + no admin/analytics read path (out of scope); scoped by `account_id` like all other tenant data |
| **Servings default ambiguity** breaks shopping-list math silently | Medium | Explicit default resolved by owner before design (see Open Questions) |

## Rollback Plan

- **Constraint extraction**: environment/config toggle re-enables
  `parse_modification/1`-only mode; no schema change required to roll back.
- **Narration**: purely additive `narration` field on existing broadcast
  events; clients ignoring it are unaffected; revertible independently.
- **Variable servings**: riskiest slice (migration + payload + Python
  contract). `servings` defaults such that omission behaves as `1` (today's
  implicit behavior); down-migration drops the column; `optimizador.py`
  reverts to unscaled candidates.
- **Catastrophic**: revert to `fix/planning-pipeline-plumbing` baseline;
  regex-only chat and single-serving assumption fully restored.

## Dependencies

- `fix/planning-pipeline-plumbing` merged (empty-candidates bug, optimizer
  config, atomic confirm, no eager shopping-list-at-confirm) — hard
  prerequisite, not re-scoped here.
- `GEMINI_API_KEY` configured; confirm `gemini-2.5-flash-lite` supports
  native JSON-schema-constrained output, or fall back to strict-JSON-mode
  prompting (design-phase decision).
- `meal_planner_api/openspec/config.yaml` — `strict_tdd: true`,
  `max_changed_lines: 400` → chained-PR delivery required.

## Delivery Slicing (chained PRs, ~400-line budget each)

| PR | Scope | Depends on |
|---|---|---|
| 1 | `servings` migration + `ScheduledMeal`/`Recipe` wiring + `proposal_json` slot shape | — |
| 2 | Optimizer payload + `optimizador.py` scaling + `PayloadAdapter` | PR 1 |
| 3 | Shopping quantity scaling + cooking-completion inventory scaling | PR 1 |
| 4 | LLM constraint extraction (`GeminiClient` extraction path, `ConstraintDelta` changeset, `Server.chat` rewiring, fallback circuit breaker) | PR 1 (extracts into `servings`) |
| 5 | LLM narration + channel wiring + (conditional) `planning_chat_messages` persistence | PR 4 |

## Success Criteria

- [ ] A free-text chat message with a per-slot guest-count override produces
      a validated constraint delta and a re-solved proposal with correctly
      scaled costs/macros for that slot only.
- [ ] Hallucinated/out-of-range LLM extractions are rejected before reaching
      `OptimizerServer` and produce a clarification narration, not a crash.
- [ ] `ScheduledMeal.servings`, `proposal_json` slots, and the optimizer
      payload all carry the same per-slot servings value end-to-end.
- [ ] Shopping-list quantities for a 10-serving Sunday slot are ~2.5x a
      4-serving slot's quantities for the same recipe (not raw-copied).
- [ ] Post-solve narration references the user's actual constraints (dates,
      guest counts) without altering any recipe ID, quantity, or price.
- [ ] Regex fallback (`parse_modification/1`) still works when the LLM client
      errors or is disabled.
- [ ] `mix precommit` passes; new coverage for constraint validation,
      servings scaling, and narration wiring.

## Proposal Question Round

These are open product decisions the owner should resolve (or explicitly
defer) before `sdd-design`:

1. **Default servings source** — when a chat message doesn't specify guest
   count, what sets `requested_servings`? Leading candidates: active
   `AccountMembership` count for the account, or `Account.plan` family size
   (`family_4`/`family_6`). This changes both solver cost/macros and shopping
   quantities by default, so getting it wrong silently overspends or
   underbuys groceries.
2. **Ambiguity/negotiation behavior** — when an extraction is ambiguous or
   conflicts with an existing constraint (e.g., asked budget can't fit the
   macro floor), should the LLM ask a clarifying follow-up before
   re-invoking the solver, or should it solve anyway and narrate the
   tradeoff it had to make? This decides whether we need a clarification-turn
   subsystem in v1 or can defer it.
3. **Iteration budget** — is there any product-level limit on how many times
   a user can iterate before being nudged to accept ("looks like you're
   still adjusting — want me to lock in the closest match?"), given each
   iteration costs a Gemini call plus an OR-Tools solve? Or is unlimited
   iterate-until-happy the intended UX with no friction?
4. **Chat history persistence** — is conversational context scoped only to
   the in-flight generation session (discarded on confirm/reject), or should
   past weeks' negotiation be retrievable later (e.g., "why did you plan
   chicken twice")? This decides whether `planning_chat_messages` ships in
   this change or is deferred.
5. **Guest-override precision** — for a single-day servings override (10
   guests, Sunday only), is exact `quantity × factor` sufficient for the
   shopping list in v1, or does the product expect packaging-aware rounding
   (e.g., round up to whole packages) from day one?

If no response is given before design starts, this proposal's working
assumptions are: (1) `AccountMembership` count as the default, (2) solve-and-
narrate-the-tradeoff (no clarification subsystem in v1), (3) no hard
iteration limit, (4) persist chat history (`planning_chat_messages` ships),
(5) exact quantity scaling, no packaging rounding.
