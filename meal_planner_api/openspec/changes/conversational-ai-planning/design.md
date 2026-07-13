# Design: Conversational AI Meal Planning

> **Change**: `conversational-ai-planning`
> **Owner sub-project**: `meal_planner_api`
> **Status**: `design` (proposal + 4 specs approved; design ready for `sdd-tasks`)
> **Upstream artifacts**: [`proposal.md`](proposal.md), [`specs/`](specs/).
> **Prerequisite**: `fix/planning-pipeline-plumbing` (candidates fix, optimizer config, atomic confirm, eager shopping-at-confirm) — treated as a merged baseline, not re-scoped here.
> **Review budget**: 400 changed lines per PR → 7 chained PRs (see §8).
> **Architecture invariants**: Clean Architecture boundaries (`Web` thin, `Application`/`Services` own use cases, `Persistence` owns queries — `meal_planner_api/ARCHITECTURE.md`). `mix precommit` for verification, `strict_tdd: true`.

## 1. Architecture Overview

This change wires an LLM into both ends of the existing solver pipeline
(`PlanningChannel` → `Generation.Server` → `PayloadAdapter` →
`OptimizerServer` → `optimizador.py`) without changing that pipeline's
shape: constraint extraction replaces the regex `parse_modification/1` as
the *primary* interpretation of chat turns (regex becomes a circuit-breaker
fallback), and a second, strictly read-only LLM turn narrates the solved
plan. Both LLM entry points reuse the existing `MealPlannerApi.AI` façade
and `Client` behaviour (`GeminiClient` / `MockClient`, env-based selection)
— no new provider abstraction. Variable servings is threaded through five
layers (`ScheduledMeal`, `proposal_json`, the optimizer payload,
`optimizador.py`, `ShoppingRepo`/`CookingService`) using **two different
scaling factors**, not one — this is the single most important correction
this design makes to the proposal (see §2).

Direct-read findings that shape every decision below:

- `optimizador.py`'s `candidates_by_slot` is keyed **only by slot type**
  (`"lunch"`, `"dinner"`, ...), shared across all 7 days — there is no
  existing per-day candidate axis. Per-day servings variance ("Sunday for
  10, rest of the week for 4") must be injected as a *separate* dimension,
  not by duplicating candidate lists per day.
- Every numeric field on a candidate (`estimated_cost_cents`,
  `protein_g_per_serving`, `carbs_g_per_serving`, `fat_g_per_serving`,
  `calories_per_serving`) is **already a single-serving value** — confirmed
  by `PriceService.fetch_recipe_prices_float/1` (`price_per_serving_cents`)
  and `Recipe`'s own field names. `Recipe.servings` never enters this data
  path today.
- `RecipeIngredient.quantity_milli` (`recipe_ingredients` table) is, by
  contrast, a **whole-recipe-batch** quantity (no `_per_serving` field
  exists on that schema) — it is copied raw into `ShoppingItem` in
  `ShoppingService.ensure_shopping_items_from_schedule/3` and subtracted raw
  in `CookingService.persist_finish/2`. This is the one place
  `Recipe.servings` is the correct divisor.
- `OptimizerServer` already implements a GenServer-owned circuit breaker
  (`@circuit_failure_threshold 3`, `@circuit_reset_timeout_ms 30_000`,
  `OptimizerFallback` heuristic) — the LLM circuit breaker in §4 mirrors
  these exact constants for consistency, not because 3/30s is independently
  derived for LLM calls.
- `MealPlannerApi.AI.Client` currently exposes only
  `stream_chat_completion/3` and `generate_text/2` — no JSON-schema-
  constrained output callback exists; `AIChannel` and `CookingService`'s
  `answer_question/4` are the only current callers.

## 2. Decision — Servings-Scaling Formula (`optimizador.py`)

**Correction to the proposal and to `specs/variable-servings.md`**: both
state the optimizer scaling factor as `requested_servings / recipe.servings`
and give a worked example ("recipe with `servings: 4` and base cost $8...
10 servings → $8 × 10/4 = $20"). Applied literally to the *actual* candidate
fields (`estimated_cost_cents` etc., confirmed **per-serving** above), this
formula is wrong: it would divide an already-per-unit value by
`recipe.servings` a second time, silently under-scaling cost and macros by
a factor of `1/recipe.servings` (a `servings: 8` family recipe would price
8× too cheap). The worked example is only internally consistent if "base
cost $8" means the recipe's *total* batch cost — but the payload never
carries that; it carries `price_per_serving_cents`.

**Choice**: two distinct factors, applied at the two places that actually
need them:

| Data | Native shape | Correct factor | Where applied |
|---|---|---|---|
| `estimated_cost_cents`, `*_per_serving` macros in `candidates_by_slot` | Already per single serving | `requested_servings` (direct multiply, no division) | `optimizador.py` `_solve/1`, per (day, slot) |
| `RecipeIngredient.quantity_milli` | Whole-recipe batch (yields `recipe.servings` portions) | `requested_servings / recipe.servings` | `ShoppingService`/`ShoppingRepo`, `CookingService.persist_finish/2` |

**Alternatives considered**: (a) apply `requested_servings / recipe.servings`
uniformly as literally proposed — rejected, demonstrated incorrect above;
(b) pre-multiply `recipe.servings` back into the candidate fields before
sending to Python so a single ratio formula "works" — rejected, adds a
round-trip unit conversion for no benefit, and risks a future regression if
someone re-derives the ratio from the (now double-scaled) candidate data.

**Payload schema change** (precise): `candidates_by_slot` keeps its current
per-slot-type shape (recipe pools don't vary by day). A new top-level field
`requested_servings` is added, a flat map keyed by the **same slot-key
format** `GenerationService.slot_key/2` already produces
(`"YYYY-MM-DD_slot"`, e.g. `"2026-07-19_lunch"`):

```json
{
  "days": ["2026-07-19", "2026-07-20"],
  "slots": ["lunch", "dinner"],
  "constraints": { "weekly_budget_cents": 50000, "macro_bounds": {...} },
  "candidates_by_slot": { "lunch": [...], "dinner": [...] },
  "requested_servings": {
    "2026-07-19_lunch": 10,
    "2026-07-19_dinner": 10,
    "2026-07-20_lunch": 4,
    "2026-07-20_dinner": 4
  }
}
```

Elixir resolves **every** default before building the payload (Python never
computes a default — it only consumes fully-resolved values, so it needs no
`AccountMembership` awareness). `_validate_payload` gains a check: every
`day_slot` combination in `days × slots` must have a `requested_servings`
entry, a positive number → `missing_servings` / `invalid_servings` errors.

**`_solve` changes** (numeric types: `_candidate_num/2` already coerces
every candidate field to `float`; the factor is cast to `float` too —
`int * float` cent-money mixing that existed before is unchanged, OR-Tools
accepts float coefficients):

```python
factor = float(requested_servings[f"{day}_{slot}"])

objective_terms.append(
    var * _candidate_num(candidate, "estimated_cost_cents") * factor
)
...
terms.append(
    x[(day, slot, index)] * _candidate_num(candidate, candidate_key) * factor
)
```

applied identically to the cost objective term, the budget-constraint term,
and each of the 4 macro terms. `weekly_budget_cents` and `macro_bounds`
themselves are **not** rescaled — they already represent the household's
weekly money/nutrition targets as submitted; only the per-candidate
contribution toward those targets scales with headcount, per
`specs/variable-servings.md`'s explicit "macro bounds scale consistently
with cost" scenario (macro bounds are treated as an aggregate target for
however many people eat that slot, which the spec deliberately chose over a
per-account-holder-only nutrition reading).

**`PayloadAdapter.build_optimizer_payload/3`** gains the `requested_servings`
field, sourced from each slot map's new `:requested_servings` key (set by
`Generation.Server.build_slots_input/1`, not nested inside
`slot.constraints` — it is a solver dimension, not a candidate-scoped
nutrition bound):

```elixir
requested_servings =
  Enum.into(slots, %{}, fn slot ->
    {GenerationService.slot_key(slot.date, to_string(slot.slot)), slot.requested_servings || 1}
  end)
```

## 3. Decision — Gemini Structured Output

**Choice**: add a new `Client` behaviour callback for schema-constrained
JSON, using Gemini's native `responseMimeType: "application/json"` +
`responseSchema` in `generationConfig` (supported by `gemini-2.5-flash-lite`
and the wider Gemini 1.5/2.x family) as the **primary** reliability
mechanism, not prompt-and-parse:

```elixir
# lib/meal_planner_api/ai/client.ex
@callback generate_structured(prompt(), schema :: map(), keyword()) ::
            {:ok, map()} | {:error, term()}
```

`GeminiClient.generate_structured/3` builds the same request shape as
`do_generate/3` but adds `responseSchema: schema` to `generationConfig`,
still parses `candidates[0].content.parts[0].text` (Gemini returns the JSON
as text even in schema mode) and `Jason.decode/1`s it — decode failure is
`{:error, :invalid_json}`, routed to the fallback path in §4.
`MockClient.generate_structured/3` returns `opts[:mock_response]` when
given (test fixtures), else a minimal empty-but-valid `ConstraintDelta` map;
`opts[:force_error]` lets tests exercise the circuit breaker deterministically without needing a real HTTP failure.

**Alternatives considered**: (a) strict-JSON-mode system-prompt + regex/`Jason` parsing only — kept only as what happens if `responseSchema` is rejected by the pinned model (config flag `:gemini_structured_output_enabled`, default `true`, flips the request builder to system-prompt mode); (b) a brand-new `AI.Structured` behaviour separate from `Client` — rejected, fragments the client-selection pattern `MealPlannerApi.AI` already owns.

`MealPlannerApi.AI` gains `extract_constraints/2`, reusing the exact
`client/0` + `ensure_client_ready/1` dispatch `generate_text/2` already uses:

```elixir
def extract_constraints(message, opts \\ []) do
  with {:ok, client_module} <- client(),
       :ok <- ensure_client_ready(client_module) do
    client_module.generate_structured(message, ConstraintDelta.json_schema(), opts)
  end
end
```

## 4. Decision — Where Extraction Lives in the Flow

**Choice**: a new lightweight `MealPlannerApi.AI.CircuitBreaker` GenServer
(new module — `AI.generate_text`/`extract_constraints` are currently
stateless HTTP calls with no supervising process, unlike `OptimizerServer`
which already owns Port state) tracks consecutive extraction failures with
the *same* threshold/reset constants as `OptimizerServer`
(`3` failures → open, `30_000`ms reset), exposing `open?/0`,
`record_success/0`, `record_failure/0`. `Generation.Server.handle_chat/3`
becomes:

```elixir
defp handle_chat(state, proposal_id, msg, content_type) do
  if AI.CircuitBreaker.open?() do
    fallback_regex(state, proposal_id, msg)
  else
    case AI.extract_constraints(msg, session_context: session_context(state)) do
      {:ok, raw_delta} ->
        AI.CircuitBreaker.record_success()
        case ConstraintDelta.validate(raw_delta, session_context(state)) do
          {:ok, delta} -> merge_delta_and_resolve(state, proposal_id, delta)
          {:error, changeset} -> narrate_rejection(state, changeset)
        end

      {:error, _reason} ->
        AI.CircuitBreaker.record_failure()
        fallback_regex(state, proposal_id, msg)
    end
  end
end
```

`fallback_regex/3` is today's `handle_chat/3` body verbatim
(`GenerationService.parse_modification/1` + `apply_modification_to_state/2`)
— unchanged, not deleted, per the proposal's rollback plan.

**State/accumulation**: `state` gains `:servings_overrides` (map,
`%{"2026-07-19" => 10}`, later turns override earlier per-date values) and
`:default_servings` is deliberately **not** stored in state — per
`specs/variable-servings.md` ("re-evaluated per solve... not cached"), it
is recomputed inside `run_pipeline/1` on every solve:

```elixir
default_servings =
  account_id
  |> MealPlannerApi.AccountsMembership.count_active_memberships()
  |> max(1)
```

(`AccountsMembership.count_active_memberships/1` is new, backed by a new
`AccountMembershipQueries.count_active/1` — following that module's own
documented "single source of truth" convention rather than adding a fourth
independent COUNT query.) `build_slots_input/1` resolves per-(date,slot)
servings as `Map.get(overrides, date, default_servings)`.

`input_context` on `planning_generation_runs` stays write-once at
generation start (today's behavior); the durable multi-turn record is
`planning_chat_messages` (§6) plus each turn's validated `ConstraintDelta`,
not a rewritten `input_context` snapshot — this keeps `do_confirm/2`
unchanged.

## 5. Decision — `ConstraintDelta` Validation Gate

**Choice**: `MealPlannerApi.Persistence.Planning.ConstraintDelta`, an
`embedded_schema` (no table), validated in **two tiers** matching the two
spec scenarios that need different failure modes:

1. **Sanitize (soft-drop, never fails the whole delta)** —
   `excluded_ingredient_ids` / `favorite_recipe_ids` are checked against the
   catalog (`RecipeRepo`); unknown IDs are filtered out of that field before
   the changeset runs ("dropped from the merge, not silently coerced").
2. **Changeset (hard reject, whole delta discarded)** — numeric/date bounds:

```elixir
embedded_schema do
  field :budget_cents, :integer
  field :date_from, :date
  field :date_to, :date
  field :protein_g_min, :integer
  field :protein_g_max, :integer
  # ...carbs_g_min/max, fat_g_min/max, calories_min/max
  field :excluded_ingredient_ids, {:array, :binary_id}, default: []
  field :favorite_recipe_ids, {:array, :binary_id}, default: []
  field :servings_overrides, :map, default: %{}
end

def changeset(delta, attrs, %{date_from: week_from, date_to: week_to}) do
  delta
  |> cast(attrs, [...])
  |> validate_number(:budget_cents, greater_than: 0, less_than_or_equal_to: @max_budget_cents)
  |> validate_date_within_week(:date_from, week_from, week_to)
  |> validate_date_within_week(:date_to, week_from, week_to)
  |> validate_servings_overrides(week_from, week_to)
end
```

`validate_servings_overrides/3` rejects the whole delta if any map key
fails `Date.from_iso8601/1` or falls outside `[week_from, week_to]`, or any
value is outside `1..20` (`ServingsPolicy.max_servings/0` — a new shared
constant module used by `ConstraintDelta`, `ScheduledMeal`, and the
optimizer-payload validator, so the cap is defined once). Injection stance:
LLM output is DATA — every numeric value is clamped/validated before
`PayloadAdapter` ever sees it; on hard rejection the turn produces a
clarification narration (§6), never a crash, never a silent pass-through.

## 6. Decision — Narration Turn

**Choice**: `AI.narrate_plan/2` runs `generate_text/2` (plain prose, not
`generate_structured`) after `proposal_json` is persisted, fed **only**
already-solved data (slots, recipe names, prices, macros — read-only
serialization) plus the accumulated constraint/assumption context (defaulted
servings, budget/macro tradeoffs the solver had to make, current iteration
count). Return type is `{:ok, String.t()}` — a type-level guarantee that no
code path can feed narration output back into `proposal_json`,
`ScheduledMeal`, or the optimizer payload; the frontend renders numeric plan
data from `proposal_json` exactly as today, narration is a separate text
field rendered beside it, never a data source.

**Streaming — scope reduction vs. the proposal**: the proposal specifies
narration reuses `AIChannel`/`GeminiClient`'s SSE plumbing for token-by-
token delivery. None of `specs/plan-narration.md`'s Given/When/Then
scenarios assert incremental delivery — only that narration references
correct data, never blocks the proposal, and is additive. **This design
ships synchronous narration in PR 7** (`generate_text/2`, full text,
included directly in the same `proposal_ready`/`proposal_update` broadcast)
to satisfy every acceptance scenario with materially less surface area;
true token streaming (a second topic, e.g. `"planning_narration:#{proposal_id}"`,
bridged via `GeminiClient.stream_chat_completion/3`) is deferred as an
explicit fast-follow, flagged in Open Questions. Narration failure
(`{:error, _}`) broadcasts `narration: nil` and never blocks the proposal
event, per spec.

**Iteration nudge**: `Generation.Server` state gains `:solve_count`
(incremented once per `run_pipeline/1` call within a session); once
`>= @soft_iteration_threshold` (config, default `5`), the narration prompt
includes the running count so the LLM appends a gentle nudge — no hard cap
enforced anywhere in code.

**Infeasibility narration (gap the proposal doesn't cover)**:
`handle_optimization_error/3` today only broadcasts
`{reason: Atom.to_string(reason)}`. This design adds a narration call on
that path too (`AI.narrate_infeasibility/2`, same read-only contract, fed
the constraint context that produced `no_optimal_solution`) so the user
gets a plain-language explanation ("no pude armar el domingo con $30 para
10 personas y 100g de proteína") instead of a raw error atom.

## 7. Decision — `planning_chat_messages` Schema + Conversation Window

```elixir
schema "planning_chat_messages" do
  field :role, Ecto.Enum, values: [:user, :assistant]
  field :content, :string
  field :content_type, Ecto.Enum, values: [:text, :speech_transcript], default: :text

  belongs_to :account, MealPlannerApi.Persistence.Accounts.Account
  belongs_to :generation_run, MealPlannerApi.Persistence.Planning.PlanningGenerationRun

  timestamps(type: :utc_datetime_usec, updated_at: false)
end
```

Indexes: `[:generation_run_id, :inserted_at]` (context-window query order),
`[:account_id]` (tenancy scoping, consistent with `EnforceAccountScope`
conventions from Phase A). Insert-only — no update path. New
`Data.PlanningChatMessageRepo` (`create_message/1`,
`list_recent_for_run/2`).

**Context window**: extraction/narration assemble context by querying the
**last `N`** rows for `generation_run_id` ordered by `inserted_at` (config
`:planning_chat_context_window`, default `20`) — a sliding window, not full
unbounded replay, bounding both prompt token cost and the "Context survives
a reconnect" scenario (single-week negotiation sessions are short-lived).
`Generation.Server.handle_chat/3` inserts the `:user` row before extraction
and the `:assistant` row after narration (or the fallback string) so the
transcript is always complete.

## 8. Migration / Compatibility

- **`ScheduledMeal.servings`**: `add :servings, :integer, null: false, default: 1`
  in one migration — Postgres backfills existing rows with the default at
  column-add time; no separate data migration needed (unlike Phase A's
  `AccountMembership` backfill, which inferred data cross-table). Matches
  the spec's explicit "defaulting to 1... preserving today's implicit
  behavior on rollback."
- **`proposal_json` version compatibility for pending proposals**: **no
  shim needed**. `Generation.Server` is `restart: :temporary`,
  Registry-backed, and tied to a live channel socket — a deploy/restart
  already destroys every in-flight (`:pending`) generation today, before
  this change. Only `:accepted` proposals are durably meaningful, and those
  are already converted into `ScheduledMeal` rows (which get `servings` via
  its own column default). This removes an entire versioning-shim
  subsystem from scope.

## 9. Delivery Slicing (refines the proposal's 5-PR chain to 7)

Direct code reading surfaced more moving parts than the proposal estimated
(a new `CircuitBreaker` GenServer, a two-tier `ConstraintDelta` sanitize/
validate pipeline, a corrected two-formula scaling scheme) — refined into 7
slices, each independently revertible, sequential Feature-Branch-Chain
(`fix/planning-pipeline-plumbing` merged first, external to this chain):

| PR | Scope | Depends on | Est. LOC |
|---|---|---|---|
| 1 | `servings` migration, `ScheduledMeal` changeset, `proposal_json` slot shape (`requested_servings` key), `AccountMembershipQueries.count_active/1` + `AccountsMembership.count_active_memberships/1` | — | ~280 |
| 2 | `optimizador.py` two-formula scaling + payload `requested_servings` map + `PayloadAdapter` + `build_slots_input` default resolution; property tests servings 1–20 | PR 1 | ~340 |
| 3 | Shopping quantity scaling (`ShoppingRepo`, `ShoppingService`) + cooking-completion inventory scaling (`CookingService.persist_finish/2`) | PR 1 | ~220 |
| 4 | `Client.generate_structured/3` + `GeminiClient`/`MockClient` impls + `ConstraintDelta` embedded schema (sanitize + changeset) — additive, unwired | — | ~380 (flag for further split into 4a/4b if review pushes back) |
| 5 | `AI.CircuitBreaker` GenServer + `Generation.Server.handle_chat/3` rewiring + `:servings_overrides` state | PR 1, PR 4 | ~300 |
| 6 | `planning_chat_messages` migration + schema + `PlanningChatMessageRepo` + persistence calls in `handle_chat` | PR 5 | ~200 |
| 7 | `AI.narrate_plan/2` + `AI.narrate_infeasibility/2` + `PlanningChannel` `narration` field (synchronous, per §6) | PR 5 | ~260 |

`400-line budget risk: Low` per slice; `Chained PRs recommended: Yes`;
`Decision needed before apply: No` (delivery strategy already resolved as
chained per `openspec/config.yaml`).

## 10. Testing Strategy

| Layer | What to Test | Approach |
|---|---|---|
| Unit (Python) | `_solve` two-formula scaling correctness | `test/` (or a Python test harness if absent) — property test: `scaled_cost == per_serving_cost * requested_servings` across `servings ∈ 1..20`, independent of `recipe.servings` |
| Unit (Elixir) | `ConstraintDelta` sanitize + changeset (both tiers) | `constraint_delta_test.exs` — hallucinated IDs dropped, out-of-range servings/budget/dates hard-rejected |
| Unit (Elixir) | `AI.CircuitBreaker` threshold/reset | mirrors `OptimizerServer`'s own circuit-breaker test shape |
| Integration | `PayloadAdapter` `requested_servings` map shape | `payload_adapter_test.exs` — mixed per-day servings produce a distinct map, not a shared value |
| Integration | Shopping/inventory scaling factor | `shopping_repo_test.exs`, `cooking_service_test.exs` — 10-serving vs 4-serving slot ≈ 2.5× |
| Integration | Narration read-only guarantee | assert `proposal_json` byte-identical before/after narration call |
| E2E | Full "Sunday for 10" negotiation | see §11 |

## 11. Verification

End-to-end checkpoint scenario ("Sunday for 10"):

1. Start a generation for the current week (`generate_menu`).
2. Send chat: *"Domingo cocinamos para 10, el resto de la semana para 4."*
3. Assert the extracted `ConstraintDelta` carries
   `servings_overrides: %{"<sunday-date>" => 10}` and the changeset accepts
   it (within `1..20`, date inside the week).
4. Assert the optimizer payload's `requested_servings` map has `10` for
   Sunday's slots and `4` (the resolved `AccountMembership`-count default)
   for every other slot.
5. Assert the re-solved `proposal_json` slots carry matching
   `requested_servings`, and — for a candidate constrained to the same
   `recipe_id` across two days — Sunday's contribution to the objective/
   macro terms is exactly `10/4 = 2.5×` the weekday slot's, not scaled by
   `recipe.servings`.
6. Confirm the proposal; assert `ScheduledMeal.servings` is `10` for Sunday
   rows and `4` elsewhere.
7. Assert Sunday's shopping items are `2.5×` a same-recipe 4-serving day's
   `quantity_milli` for shared ingredients (the *other* formula, §2).
8. Assert narration text references "10" and "4" and that `proposal_json`
   is byte-identical before/after the narration call.
9. Force a Gemini failure (`MockClient` `opts[:force_error]`) for 3
   consecutive turns; assert the circuit opens, `parse_modification/1`
   handles the 4th turn, and chat keeps working (no crash, no 500).
10. Force an infeasible combination (e.g. `$5` budget + `100g` protein floor
    for 10 servings); assert `generation_error` still broadcasts **and** a
    plain-language infeasibility narration is included.

## 12. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Servings-formula regression** (this design's central correction) — if a future change re-derives the proposal's literal `requested_servings / recipe.servings` ratio against the per-serving candidate fields, costs/macros silently under-scale by `1/recipe.servings` | Medium | Property test locks the exact formula (§10); code comment at the `_solve` scaling site cross-referencing this design section |
| LLM cost/latency — up to 2 Gemini calls per turn (extraction + narration), 3 on an infeasible re-solve | High | `maxOutputTokens` caps, sliding 20-turn chat window, soft iteration nudge (default 5), circuit-breaker fallback to regex |
| Prompt injection | High | `ConstraintDelta` schema + two-tier sanitize/changeset gate; narration is read-only prose, type-level inability to write back into plan data |
| Solver infeasibility from over-constrained extractions | Medium | `AI.narrate_infeasibility/2` (new, §6) explains the tradeoff instead of a raw error atom; changeset bounds reduce how extreme an extraction can be before it even reaches the solver |
| `planning_chat_messages` content sensitivity | Medium | Account-scoped only, no admin/analytics read path (out of scope), insert-only |
| Streaming scope reduction (synchronous narration in PR 7 vs. proposal's SSE ask) | Low | All spec scenarios pass without token streaming; true streaming is a scoped fast-follow, not silently dropped |

## Open Questions

- [ ] Confirm `gemini-2.5-flash-lite` accepts `responseSchema` in
      `generationConfig` against the live API before PR 4 lands (design
      assumes yes based on the documented Gemini 1.5/2.x family behavior;
      `:gemini_structured_output_enabled` flag is the fallback toggle if not).
- [ ] Fast-follow: true token-streaming narration over a
      `"planning_narration:#{proposal_id}"` topic, once PR 7's synchronous
      version ships and UX feedback requests it.
- [ ] Whether PR 4 (~380 LOC) needs a further 4a/4b split once real diffs
      are drafted — flagged, not yet split.

## Next Step

Ready for `sdd-tasks`. All 8 requested design decisions are resolved, the
servings-formula correction is locked with a verification property test,
the 7-PR chained delivery plan is concrete, and the E2E checkpoint scenario
in §11 is ready to become the acceptance test for `sdd-tasks`/`sdd-apply`.
