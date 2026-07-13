# Tasks — conversational-ai-planning

> **Change**: `conversational-ai-planning` — LLM constraint extraction, LLM narration, variable servings, planning chat history.
> **Owner sub-project**: `meal_planner_api`.
> **Upstream artifacts**: [`proposal.md`](proposal.md), [`design.md`](design.md), [`specs/`](specs/) (4 specs).
> **TDD mode**: `strict_tdd: true`, `test_runner: "mix test"`, `max_changed_lines: 400`.
> **Hard prerequisite**: `fix/planning-pipeline-plumbing` (empty-candidates fix, optimizer config, atomic confirm, eager shopping-at-confirm) is treated as a **merged baseline** — not re-scoped by any task below.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1,520 added / ~120 modified (~1,400 net) across 7 PRs |
| 400-line budget risk | Low (per slice) |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 → PR 4 → PR 5 → PR 6 → PR 7 (design §9) |
| Delivery strategy | chained (per `openspec/config.yaml`, `chained_pr_recommended_above: 400`) |
| Chain strategy | feature-branch-chain (`fix/planning-pipeline-plumbing` merged first, external to this chain) |

```text
Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Low
```

### Suggested Work Units

| Unit | Goal | PR | Base branch |
|---|---|---|---|
| 1 | `servings` migration, `ScheduledMeal` changeset, `proposal_json` shape, membership-count query | PR 1 | tracker/`fix/planning-pipeline-plumbing` |
| 2 | `optimizador.py` two-formula scaling, payload `requested_servings`, `PayloadAdapter` | PR 2 | PR 1 branch |
| 3 | Shopping/inventory quantity scaling | PR 3 | PR 1 branch (parallel-safe with PR 2) |
| 4 | `generate_structured/3`, `ConstraintDelta` schema (additive, unwired) | PR 4 | PR 1 branch (parallel-safe with PR 2/3) |
| 5 | `AI.CircuitBreaker`, `handle_chat` rewiring, multi-turn merge | PR 5 | PR 2 + PR 4 branches |
| 6 | `planning_chat_messages` persistence + context window | PR 6 | PR 5 branch |
| 7 | Narration (`narrate_plan`/`narrate_infeasibility`), channel wiring, full E2E checkpoint | PR 7 | PR 5 branch (parallel-safe with PR 6) |

### Test conventions (project-wide)

- **RED → GREEN** for every task (strict TDD); no REFACTOR-only tasks except where noted.
- Use `start_supervised!/1` for GenServer tests (never `Process.sleep/1`).
- `MockClient` is the honesty contract for every AI-touching task: `opts[:mock_response]` for fixtures, `opts[:force_error]` for deterministic circuit-breaker tests.
- Prompt-injection stance (repeated per LLM-touching task): LLM output is DATA, never trusted directly — `ConstraintDelta`'s changeset gate (sanitize + hard-reject tiers) is the only path into the solver; narration is read-only prose with no write-back code path.
- Run scoped tests, then `mix precommit` before merge; Python changes run via the existing `optimizador.py` test harness.

---

## PR 1 — Servings foundation

**Goal**: land the data model and shape changes so later PRs can wire real values through.
**Depends on**: none (first slice).

### Task 1.1 — Migration: add `servings` to `scheduled_meals`
- **Files**: `priv/repo/migrations/20260713100000_add_servings_to_scheduled_meals.exs` (new); `test/meal_planner_api/persistence/planning/scheduled_meal_test.exs` (extend, RED first)
- **Type**: test-first
- **Description**: `add :servings, :integer, null: false, default: 1` + CHECK `servings > 0 AND servings <= 20` (spec `variable-servings` "ScheduledMeal carries a servings value"). Column default backfills existing rows; no separate data migration (design §8).
- **Acceptance criteria**:
  - [ ] test inserts a changeset with `servings: 10` and asserts it persists (RED — column absent)
  - [ ] migration runs; test GREEN
  - [ ] raw SQL insert with `servings: 25` raises `check_violation` (DB-level backstop)
- **Estimated lines**: +45 / -0
- **Depends on**: none

### Task 1.2 — `ScheduledMeal` schema + changeset servings validation
- **Files**: `lib/meal_planner_api/persistence/planning/scheduled_meal.ex` (modify); `test/.../scheduled_meal_test.exs` (extend)
- **Type**: test-first
- **Description**: add `field(:servings, :integer, default: 1)`; changeset casts `:servings`, validates `> 0` and `<= ServingsPolicy.max_servings()` (task 1.3).
- **Acceptance criteria**:
  - [ ] test asserts changeset invalid for `servings: 0` and `servings: 21` (RED — spec "Out-of-cap servings rejected at the schema level")
  - [ ] test asserts changeset defaults to `1` when omitted
  - [ ] schema/changeset updated; tests GREEN
- **Estimated lines**: +30 / -5
- **Depends on**: 1.1, 1.3

### Task 1.3 — `MealPlannerApi.ServingsPolicy` shared constant module
- **Files**: `lib/meal_planner_api/servings_policy.ex` (new); `test/meal_planner_api/servings_policy_test.exs` (new)
- **Type**: test-first
- **Description**: single source of truth `max_servings/0 :: 20`, reused by `ScheduledMeal` (1.2), `ConstraintDelta` (PR 4), and the shared scaling helper (PR 3) — design §5.
- **Acceptance criteria**:
  - [ ] test asserts `ServingsPolicy.max_servings() == 20` (RED — module absent)
  - [ ] module written; test GREEN
- **Estimated lines**: +15 / -0
- **Depends on**: none

### Task 1.4 — `AccountMembershipQueries.count_active/1`
- **Files**: `lib/meal_planner_api/persistence/accounts/account_membership_queries.ex` (extend); `test/.../account_membership_queries_test.exs` (extend)
- **Type**: test-first
- **Description**: `count_active(account_id) :: non_neg_integer()` — counts `:active` `account_memberships` rows, following the module's existing single-source-of-truth convention.
- **Acceptance criteria**:
  - [ ] test seeds 3 `:active` + 1 `:suspended` membership, asserts count `== 3` (RED)
  - [ ] test asserts `0` for an account with no active memberships
  - [ ] function written; tests GREEN
- **Estimated lines**: +35 / -0
- **Depends on**: none

### Task 1.5 — `AccountsMembership.count_active_memberships/1`
- **Files**: `lib/meal_planner_api/accounts_membership.ex` (extend); `test/.../accounts_membership_test.exs` (extend)
- **Type**: test-first
- **Description**: thin context-boundary wrapper over task 1.4 (Clean Architecture — `Generation.Server` must not reach into `Persistence.Accounts` queries directly, PR 2/5 consume this).
- **Acceptance criteria**:
  - [ ] test asserts the wrapper returns the same count as the query module (RED)
  - [ ] function written; test GREEN
- **Estimated lines**: +15 / -0
- **Depends on**: 1.4

### Task 1.6 — `proposal_json` slot shape gains `requested_servings`
- **Files**: `lib/meal_planner_api/services/generation_service.ex` (modify `build_proposal_json/1`); `lib/meal_planner_api/services/planning_chat_service.ex` (modify `confirm_proposal/2`'s attrs map); `test/meal_planner_api/services/generation_service_test.exs`, `test/.../planning_chat_service_test.exs` (extend)
- **Type**: test-first
- **Description**: each slot gains `requested_servings` (defaults `1` — real per-slot value wired in PR 2). `confirm_proposal/2`'s `attrs` map gains `servings: meal["requested_servings"] || 1` so `ScheduledMeal.servings` (1.2) is populated at confirm time (spec "Confirm persists per-slot servings").
- **Acceptance criteria**:
  - [ ] test asserts `build_proposal_json/1` output includes `requested_servings` per slot, defaulting to 1 (RED)
  - [ ] test asserts `confirm_proposal/2` persists `ScheduledMeal.servings` matching the slot's `requested_servings` (RED)
  - [ ] changes applied; tests GREEN
- **Estimated lines**: +45 / -8
- **Depends on**: 1.2

### Task 1.7 — PR 1 checkpoint: servings round-trip test
- **Files**: `test/meal_planner_api/generation/servings_roundtrip_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: hand-built `proposal_json` with mixed `requested_servings` (10/4) confirmed via `confirm_proposal/2`, asserting the persisted `ScheduledMeal` rows carry matching `servings`. Narrower precursor to design §11 (full LLM/optimizer wiring lands later).
- **Acceptance criteria**:
  - [ ] Sunday `ScheduledMeal.servings == 10`, weekday rows `== 4`
  - [ ] a `servings: 25` slot is rejected by the changeset and not persisted
- **Estimated lines**: +55 / -0
- **Depends on**: 1.1, 1.2, 1.6

**PR 1 subtotal**: +240 added, -13 modified, 7 tasks. **Risk**: Low.

---

## PR 2 — Optimizer scaling + payload wiring

**Goal**: implement design §2's corrected two-factor formula in `optimizador.py` and thread `requested_servings` through the payload.
**Depends on**: PR 1.

### Task 2.1 — `optimizador.py` `_validate_payload`: require `requested_servings`
- **Files**: `optimizador.py` (modify `_validate_payload`)
- **Type**: test-first (Python)
- **Description**: every `day × slot` combination must have a positive `requested_servings` entry; missing/invalid → `missing_servings` / `invalid_servings`.
- **Acceptance criteria**:
  - [ ] test asserts a payload missing a `day_slot` key raises `missing_servings` (RED)
  - [ ] test asserts a zero/negative value raises `invalid_servings`
  - [ ] validator updated; tests GREEN
- **Estimated lines**: +30 / -2
- **Depends on**: none

### Task 2.2 — `optimizador.py` `_solve`: multiply by `requested_servings` (no division)
- **Files**: `optimizador.py` (modify `_solve`)
- **Type**: test-first (Python)
- **Description**: per design §2's correction — `factor = float(requested_servings[f"{day}_{slot}"])` multiplied directly into the cost objective term, the budget-constraint term, and all 4 macro terms. **Never** divided by `recipe.servings` (that ratio applies only to whole-batch shopping/inventory quantities, PR 3). `weekly_budget_cents`/`macro_bounds` stay unscaled.
- **Acceptance criteria**:
  - [ ] test asserts a $2/serving candidate scaled to a 10-serving slot contributes `$20`, not `$8 * (10/4)` applied to the per-serving value (RED — spec "Budget constraint sees the scaled cost")
  - [ ] test asserts macro terms scale identically (`10g/serving * 10 = 100g`, spec "Macro bounds scale consistently with cost")
  - [ ] `_solve` updated; tests GREEN
- **Estimated lines**: +40 / -10
- **Depends on**: 2.1

### Task 2.3 — Property test: locks the two-factor scaling formula
- **Files**: Python test harness file for `optimizador.py` scaling (new)
- **Type**: dedicated test (checkpoint, property-based)
- **Description**: property test across `requested_servings ∈ 1..20` asserting `scaled_value == per_serving_value * requested_servings` for cost and all 4 macros, independent of `recipe.servings` — locks design §12's central regression risk. Add a code comment at the `_solve` scaling site cross-referencing design §2.
- **Acceptance criteria**:
  - [ ] property test passes across the full range (RED before 2.2, GREEN after)
  - [ ] regression-guardrail comment added
- **Estimated lines**: +45 / -0
- **Depends on**: 2.2

### Task 2.4 — `PayloadAdapter.build_optimizer_payload/3` gains `requested_servings` map
- **Files**: `lib/meal_planner_api/optimization/payload_adapter.ex` (modify); `test/.../payload_adapter_test.exs` (extend)
- **Type**: test-first
- **Description**: payload gains a flat `requested_servings` map keyed by `GenerationService.slot_key/2`'s format (`"YYYY-MM-DD_slot"`), per design §2's payload schema.
- **Acceptance criteria**:
  - [ ] test asserts a mixed-servings slot list (Sunday 10, weekday 4) produces a distinct entry per slot-key, not one shared value (RED — spec "Payload reflects mixed servings across the week")
  - [ ] function updated; test GREEN
- **Estimated lines**: +35 / -5
- **Depends on**: 2.1

### Task 2.5 — `Generation.Server.build_slots_input/1` resolves default `requested_servings`
- **Files**: `lib/meal_planner_api/generation/server.ex` (modify `build_slots_input/1`); `test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first
- **Description**: default `requested_servings` = `AccountsMembership.count_active_memberships/1 |> max(1)` (task 1.5), re-evaluated per solve, never cached (spec "Default servings from active account memberships"). `:servings_overrides` accumulation ships in PR 5 — this task hardcodes `overrides = %{}` so default resolution is testable in isolation (documented no-op, not a bug).
- **Acceptance criteria**:
  - [ ] test asserts every slot carries `requested_servings` equal to the active-membership count when no override exists (RED)
  - [ ] test asserts an account with 0 active memberships resolves to `1`, never `0` (spec "Account with no active memberships defaults to 1")
  - [ ] function updated; tests GREEN
- **Estimated lines**: +30 / -5
- **Depends on**: 1.5, 2.4

### Task 2.6 — `PayloadAdapter.translate_response/2` threads real `requested_servings` into `proposal_json`
- **Files**: `lib/meal_planner_api/optimization/payload_adapter.ex` (extend); `lib/meal_planner_api/services/generation_service.ex` (extend `build_proposal_json/1`, replacing PR 1's placeholder default); `test/.../payload_adapter_test.exs`, `test/.../generation_service_test.exs` (extend)
- **Type**: test-first
- **Description**: `translate_response/2` attaches each optimized slot's `requested_servings` (looked up by slot-key from the original payload map).
- **Acceptance criteria**:
  - [ ] test asserts a re-solved `proposal_json` carries the real per-slot `requested_servings` (10 Sunday / 4 elsewhere), not PR 1's hardcoded default (RED)
  - [ ] functions updated; tests GREEN
- **Estimated lines**: +30 / -8
- **Depends on**: 2.4, 2.5, 1.6

**PR 2 subtotal**: +210 added, -30 modified, 6 tasks. **Risk**: Low.

---

## PR 3 — Shopping + inventory quantity scaling

**Goal**: implement design §2's *other* factor (`requested_servings / recipe.servings`) at the two whole-batch call sites.
**Depends on**: PR 1 (`ScheduledMeal.servings`).
**Grounding note**: direct read of `shopping_service.ex` confirms `ensure_shopping_items_from_schedule/3` (private) is the scheduled-meal-driven raw-copy site design targets. A second raw-copy site, `build_items_from_recipes/3`, exists for the ad-hoc/checkout recipe-id flow with no `ScheduledMeal` context to scale by — out of scope here (no servings signal available), flagged as an open question below.

### Task 3.1 — `ShoppingService.ensure_shopping_items_from_schedule/3` scales `quantity_milli`
- **Files**: `lib/meal_planner_api/services/shopping_service.ex` (modify, private fn); `test/meal_planner_api/services/shopping_service_test.exs` (extend)
- **Type**: test-first
- **Description**: computes `factor = meal.servings / recipe.servings` and sets `quantity_milli: round(ri.quantity_milli * factor)` instead of the raw copy (spec "Shopping quantities scale linearly with requested servings").
- **Acceptance criteria**:
  - [ ] test asserts a 4-serving meal for a 4-serving recipe copies unscaled (factor 1, regression)
  - [ ] test asserts a 10-serving meal for a 4-serving recipe produces `2.5x` quantity_milli per ingredient (RED — spec "10-serving slot produces ~2.5x")
  - [ ] function updated; tests GREEN
- **Estimated lines**: +25 / -5
- **Depends on**: 1.1

### Task 3.2 — Idempotent re-run regression test (`upsert_shopping_item/1`)
- **Files**: `lib/meal_planner_api/data/shopping_repo.ex` (no change — Data layer stays dumb); `test/meal_planner_api/data/shopping_repo_test.exs` (extend)
- **Type**: test-first
- **Description**: confirms re-running `ensure_shopping_items_from_schedule/3` (3.1) for the same slot replaces (not stacks) the already-scaled quantity via the existing `ON CONFLICT` clause — scaling stays call-site-owned, not duplicated in the Data layer.
- **Acceptance criteria**:
  - [ ] test asserts re-running the ensure-shopping-items path twice for a 10-serving meal leaves `quantity_milli` at the single scaled value (RED)
- **Estimated lines**: +15 / -0
- **Depends on**: 3.1

### Task 3.3 — `CookingService.persist_finish/2` scales inventory deduction
- **Files**: `lib/meal_planner_api/services/cooking_service.ex` (modify, private fn); `test/meal_planner_api/services/cooking_service_test.exs` (extend)
- **Type**: test-first
- **Description**: applies the same `factor = session.scheduled_meal.servings / session.scheduled_meal.recipe.servings` to `delta: -(ingredient.quantity_milli * factor)` (spec "Cooking-completion inventory deduction scales by the same factor").
- **Acceptance criteria**:
  - [ ] test asserts a 4-serving completion deducts unscaled quantities (regression)
  - [ ] test asserts a 10-serving completion (base recipe `servings: 4`) deducts `2.5x` per-ingredient quantities (RED)
  - [ ] function updated; tests GREEN
- **Estimated lines**: +25 / -5
- **Depends on**: 3.1

### Task 3.4 — Shared `scaling_factor/2` helper (DRY the whole-batch formula)
- **Files**: `lib/meal_planner_api/servings_policy.ex` (extend, task 1.3); `test/meal_planner_api/servings_policy_test.exs` (extend)
- **Type**: test-first
- **Description**: extracts `scaling_factor(scheduled_meal_servings, recipe_servings) :: float`, shared by 3.1 and 3.3, so the second formula is defined once (mirrors `max_servings/0`'s single-source-of-truth pattern).
- **Acceptance criteria**:
  - [ ] test asserts `scaling_factor(10, 4) == 2.5` (RED)
  - [ ] test asserts `scaling_factor(4, 4) == 1.0`
  - [ ] tasks 3.1 and 3.3 refactored to call it; all tests GREEN
- **Estimated lines**: +20 / -10
- **Depends on**: 1.3, 3.1, 3.3

### Task 3.5 — PR 3 checkpoint: shopping/inventory scaling integration test
- **Files**: `test/meal_planner_api/services/shopping_inventory_scaling_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: seeds a `servings: 4` recipe with two `ScheduledMeal` rows (`servings: 4` and `servings: 10`); asserts both the shopping-quantity ratio and, after marking cooked, the inventory-deduction ratio are `2.5x`.
- **Acceptance criteria**:
  - [ ] shopping ratio `== 2.5` for shared ingredients
  - [ ] inventory-deduction ratio `== 2.5` for the same ingredients
- **Estimated lines**: +40 / -0
- **Depends on**: 3.1, 3.3, 3.4

**PR 3 subtotal**: +125 added, -20 modified, 5 tasks. **Risk**: Low.

---

## PR 4 — Gemini structured output + `ConstraintDelta` (additive, unwired)

**Goal**: ship the extraction primitives without touching `Generation.Server` yet — reviewable in isolation, per design §9.
**Depends on**: none (parallel-safe with PR 2/3).

### Task 4.1 — `Client` behaviour gains `generate_structured/3`
- **Files**: `lib/meal_planner_api/ai/client.ex` (modify)
- **Type**: test-first
- **Description**: `@callback generate_structured(prompt(), schema :: map(), keyword()) :: {:ok, map()} | {:error, term()}`, mirrors `generate_text/2`'s existing shape.
- **Acceptance criteria**:
  - [ ] test asserts `function_exported?/3` is false for both `GeminiClient`/`MockClient` before 4.2/4.3 land (RED)
  - [ ] callback declared
- **Estimated lines**: +15 / -0
- **Depends on**: none

### Task 4.2 — `GeminiClient.generate_structured/3`
- **Files**: `lib/meal_planner_api/ai/gemini_client.ex` (modify); `test/meal_planner_api/ai/gemini_client_test.exs` (extend)
- **Type**: test-first
- **Description**: adds `responseSchema`/`responseMimeType: "application/json"` to `generationConfig`; parses and `Jason.decode/1`s the same text path as `do_generate/3`; decode failure → `{:error, :invalid_json}`. Config flag `:gemini_structured_output_enabled` (default `true`) falls back to strict-JSON-mode prompting (design §3 alt. (a)).
- **Acceptance criteria**:
  - [ ] test asserts the request body includes `responseSchema`/`responseMimeType` when the flag is on (RED)
  - [ ] test asserts non-JSON response text yields `{:error, :invalid_json}`
  - [ ] test asserts flag off builds the strict-JSON-mode prompt
  - [ ] function written; tests GREEN
- **Estimated lines**: +55 / -5
- **Depends on**: 4.1

### Task 4.3 — `MockClient.generate_structured/3`
- **Files**: `lib/meal_planner_api/ai/mock_client.ex` (modify); `test/meal_planner_api/ai/mock_client_test.exs` (extend)
- **Type**: test-first
- **Description**: `opts[:mock_response]` passthrough for fixtures; else a minimal valid `ConstraintDelta` map; `opts[:force_error]` returns `{:error, :forced}` for deterministic circuit-breaker tests (PR 5).
- **Acceptance criteria**:
  - [ ] test asserts `mock_response` passthrough (RED)
  - [ ] test asserts default minimal-valid-delta fallback
  - [ ] test asserts `force_error: true` returns `{:error, :forced}`
- **Estimated lines**: +30 / -0
- **Depends on**: 4.1

### Task 4.4 — `MealPlannerApi.AI.extract_constraints/2`
- **Files**: `lib/meal_planner_api/ai.ex` (modify); `test/meal_planner_api/ai_test.exs` (extend)
- **Type**: test-first
- **Description**: reuses `generate_text/2`'s exact `client/0` + `ensure_client_ready/1` dispatch; calls `client_module.generate_structured(message, ConstraintDelta.json_schema(), opts)` (task 4.6).
- **Acceptance criteria**:
  - [ ] test asserts dispatch to the configured client's `generate_structured/3` (RED)
  - [ ] test asserts client-not-ready short-circuits identically to `generate_text/2`
- **Estimated lines**: +20 / -0
- **Depends on**: 4.2, 4.3, 4.6

### Task 4.5 — `ConstraintDelta` embedded schema
- **Files**: `lib/meal_planner_api/persistence/planning/constraint_delta.ex` (new); `test/meal_planner_api/persistence/planning/constraint_delta_test.exs` (new)
- **Type**: test-first
- **Description**: `embedded_schema` per design §5 — budget, date range, macro min/max fields, `excluded_ingredient_ids`/`favorite_recipe_ids` (default `[]`), `servings_overrides` (`:map`, default `%{}`).
- **Acceptance criteria**:
  - [ ] test asserts every field/type/default from design §5 (RED — module absent)
  - [ ] schema written; test GREEN
- **Estimated lines**: +30 / -0
- **Depends on**: none

### Task 4.6 — `ConstraintDelta.json_schema/0`
- **Files**: `lib/meal_planner_api/persistence/planning/constraint_delta.ex` (extend); `test/.../constraint_delta_test.exs` (extend)
- **Type**: test-first
- **Description**: JSON-schema map matching 4.5's fields — the fixed `responseSchema` shape the LLM is constrained to (prompt-injection containment: no field outside this shape can be emitted).
- **Acceptance criteria**:
  - [ ] test asserts `json_schema/0` matches the embedded schema field-for-field (RED)
- **Estimated lines**: +25 / -0
- **Depends on**: 4.5

### Task 4.7 — `ConstraintDelta` sanitize tier (soft-drop unknown catalog IDs)
- **Files**: `lib/meal_planner_api/persistence/planning/constraint_delta.ex` (extend); `test/.../constraint_delta_test.exs` (extend)
- **Type**: test-first
- **Description**: `sanitize(raw_delta)` filters `excluded_ingredient_ids`/`favorite_recipe_ids` against `RecipeRepo`'s known IDs; unknown IDs dropped from the field, not coerced (spec "Reject a hallucinated ingredient reference").
- **Acceptance criteria**:
  - [ ] test asserts an unknown ingredient ID is dropped while valid IDs survive (RED)
- **Estimated lines**: +25 / -0
- **Depends on**: 4.5

### Task 4.8 — `ConstraintDelta.changeset/3` hard-reject tier
- **Files**: `lib/meal_planner_api/persistence/planning/constraint_delta.ex` (extend); `test/.../constraint_delta_test.exs` (extend)
- **Type**: test-first
- **Description**: `validate_number(:budget_cents, ...)`, date-within-week validators, and `validate_servings_overrides/3` (4.9).
- **Acceptance criteria**:
  - [ ] test asserts `budget_cents: 0` / negative rejected (RED)
  - [ ] test asserts a date outside the requested week rejected
- **Estimated lines**: +40 / -0
- **Depends on**: 4.5, 4.9

### Task 4.9 — `validate_servings_overrides/3`
- **Files**: `lib/meal_planner_api/persistence/planning/constraint_delta.ex` (extend); `test/.../constraint_delta_test.exs` (extend)
- **Type**: test-first
- **Description**: rejects the whole delta on a bad date key, a date outside the week, or a value outside `1..ServingsPolicy.max_servings()` (task 1.3).
- **Acceptance criteria**:
  - [ ] test asserts `servings_overrides` value `0` rejects the whole delta (RED — spec "Reject a zero-servings extraction")
  - [ ] test asserts value `5000` rejects the whole delta (RED — spec "Reject an out-of-range servings extraction")
  - [ ] test asserts an out-of-week date key rejects the whole delta
- **Estimated lines**: +35 / -0
- **Depends on**: 1.3, 4.5

**PR 4 subtotal**: +275 added, -5 modified, 9 tasks. **Risk**: Low (design flagged a possible 4a/4b split at ~380 LOC forecast; bottom-up estimate is ~270 net, no split needed — see Deviation Notes).

---

## PR 5 — Circuit breaker + `handle_chat` rewiring

**Goal**: wire extraction into `Generation.Server`, LLM-first with regex fallback.
**Depends on**: PR 1, PR 2 (task 2.5), PR 4.

### Task 5.1 — `MealPlannerApi.AI.CircuitBreaker` GenServer
- **Files**: `lib/meal_planner_api/ai/circuit_breaker.ex` (new); `test/meal_planner_api/ai/circuit_breaker_test.exs` (new)
- **Type**: test-first
- **Description**: mirrors `OptimizerServer`'s circuit breaker exactly (`@circuit_failure_threshold 3`, `@circuit_reset_timeout_ms 30_000`). Exposes `open?/0`, `record_success/0`, `record_failure/0`.
- **Acceptance criteria**:
  - [ ] test asserts 3 consecutive failures flip `open?/0` (RED)
  - [ ] test asserts success resets the failure count
  - [ ] test asserts auto-close after the reset timeout (injectable/configurable timeout for fast tests — no `Process.sleep/1`)
- **Estimated lines**: +50 / -0
- **Depends on**: none

### Task 5.2 — Register `AI.CircuitBreaker` in the supervision tree
- **Files**: `lib/meal_planner_api/application.ex` (modify); test extends existing app-boot sanity test
- **Type**: test-first
- **Description**: mirrors `OptimizerServer`'s registration.
- **Acceptance criteria**:
  - [ ] test asserts the process is alive after app boot (RED)
- **Estimated lines**: +10 / -0
- **Depends on**: 5.1

### Task 5.3 — `Generation.Server` state gains `:servings_overrides` + `:solve_count`
- **Files**: `lib/meal_planner_api/generation/server.ex` (modify state struct/`init/1`); `test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first
- **Description**: `:servings_overrides` (map, later turns override earlier per-date values), `:solve_count` (incremented once per `run_pipeline/1` call).
- **Acceptance criteria**:
  - [ ] test asserts a fresh session starts with `servings_overrides: %{}`, `solve_count: 0` (RED)
  - [ ] test asserts `run_pipeline/1` increments `solve_count`
- **Estimated lines**: +20 / -2
- **Depends on**: none

### Task 5.4 — `build_slots_input/1` consumes real `:servings_overrides`
- **Files**: `lib/meal_planner_api/generation/server.ex` (modify, task 2.5's function); test extends `server_test.exs`
- **Type**: test-first
- **Description**: replaces PR 2's `overrides = %{}` no-op with `Map.get(state.servings_overrides, date, default_servings)`.
- **Acceptance criteria**:
  - [ ] test asserts a slot whose date is in `:servings_overrides` uses the override, not the default (RED — spec "Payload reflects mixed servings")
- **Estimated lines**: +15 / -5
- **Depends on**: 2.5, 5.3

### Task 5.5 — `handle_chat/3` → `handle_chat/4`: LLM-first, regex fallback
- **Files**: `lib/meal_planner_api/generation/server.ex` (modify); `test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first
- **Description**: per design §4 — checks `AI.CircuitBreaker.open?/0` first; else `AI.extract_constraints/2`; validates via `ConstraintDelta.validate/2` (5.6); client error records a failure and calls `fallback_regex/3` (today's `handle_chat/3` body, renamed, logic unchanged per rollback plan). Rejection narration is a placeholder here (real narration ships PR 7).
- **Acceptance criteria**:
  - [ ] test asserts a successful extraction + valid delta merges and triggers a re-solve (RED)
  - [ ] test asserts an open circuit routes straight to `fallback_regex/3` without an LLM call
  - [ ] test asserts a client error records a circuit-breaker failure and falls back
  - [ ] test asserts the existing 3-pattern regex chat UX still works (regression, spec "LLM client error triggers fallback")
- **Estimated lines**: +70 / -20
- **Depends on**: 4.4, 4.8, 5.1, 5.3, 5.4

### Task 5.6 — `ConstraintDelta.validate/2` (sanitize + changeset pipeline)
- **Files**: `lib/meal_planner_api/persistence/planning/constraint_delta.ex` (extend); `test/.../constraint_delta_test.exs` (extend)
- **Type**: test-first
- **Description**: `validate(raw_delta, session_context)` runs `sanitize/1` (4.7) then `changeset/3` (4.8) — the single call site 5.5 invokes.
- **Acceptance criteria**:
  - [ ] test asserts a delta with an unknown ID + valid budget sanitizes then passes (RED)
  - [ ] test asserts a hard-reject case returns `{:error, changeset}`
- **Estimated lines**: +20 / -0
- **Depends on**: 4.7, 4.8

### Task 5.7 — Merge validated delta into the running constraint set
- **Files**: `lib/meal_planner_api/generation/server.ex` (extend `merge_delta_and_resolve/3`); test extends `server_test.exs`
- **Type**: test-first
- **Description**: later turns override earlier values for the same field/slot (spec "Second turn overrides a prior budget").
- **Acceptance criteria**:
  - [ ] test asserts turn 2's budget overrides turn 1's while unrelated servings overrides remain intact (RED)
- **Estimated lines**: +25 / -0
- **Depends on**: 5.5, 5.6

### Task 5.8 — PR 5 checkpoint: circuit-breaker fallback integration test
- **Files**: `test/meal_planner_api/generation/circuit_breaker_fallback_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: forces 3 consecutive `MockClient` `force_error: true` failures via a live `Generation.Server`; asserts the circuit opens and the 4th turn falls back cleanly (design §11 step 9, in isolation).
- **Acceptance criteria**:
  - [ ] circuit opens after 3 failures; 4th turn handled by `fallback_regex/3` with no crash
- **Estimated lines**: +30 / -0
- **Depends on**: 5.1, 5.5

**PR 5 subtotal**: +240 added, -27 modified, 8 tasks. **Risk**: Low.

---

## PR 6 — `planning_chat_messages` persistence

**Goal**: durable multi-turn history + context window.
**Depends on**: PR 5.

### Task 6.1 — Migration: `create_planning_chat_messages`
- **Files**: `priv/repo/migrations/20260714090000_create_planning_chat_messages.exs` (new); dedicated shape test
- **Type**: test-first
- **Description**: columns per design §7 (`role`, `content`, `content_type` default `:text`, `account_id` FK, `generation_run_id` FK, insert-only — `timestamps(updated_at: false)`). Indexes `[:generation_run_id, :inserted_at]`, `[:account_id]`.
- **Acceptance criteria**:
  - [ ] test asserts the table + both indexes exist (RED)
  - [ ] migration runs; test GREEN
- **Estimated lines**: +35 / -0
- **Depends on**: none

### Task 6.2 — `PlanningChatMessage` Ecto schema
- **Files**: `lib/meal_planner_api/persistence/planning/planning_chat_message.ex` (new); `test/.../planning_chat_message_test.exs` (new)
- **Type**: test-first
- **Description**: `Ecto.Enum` `role`/`content_type`; `belongs_to :account`, `belongs_to :generation_run`; required-field changeset.
- **Acceptance criteria**:
  - [ ] test asserts a valid `:user`/`:text` changeset (RED)
  - [ ] test asserts invalid enum values fail
- **Estimated lines**: +30 / -0
- **Depends on**: 6.1

### Task 6.3 — `Data.PlanningChatMessageRepo`
- **Files**: `lib/meal_planner_api/data/planning_chat_message_repo.ex` (new); `test/.../planning_chat_message_repo_test.exs` (new)
- **Type**: test-first
- **Description**: `create_message/1`, `list_recent_for_run/2` (sliding window, config `:planning_chat_context_window` default `20`), both filtering by `account_id` AND `generation_run_id` (spec "Cross-account read is rejected").
- **Acceptance criteria**:
  - [ ] test asserts `create_message/1` persists an account-scoped row (RED)
  - [ ] test asserts `list_recent_for_run/2` returns only the last N rows, chronological
  - [ ] test asserts a cross-account row is unreachable by construction
- **Estimated lines**: +35 / -0
- **Depends on**: 6.2

### Task 6.4 — `handle_chat/4` persists user/assistant turns
- **Files**: `lib/meal_planner_api/generation/server.ex` (modify, task 5.5's function); test extends `server_test.exs`
- **Type**: test-first
- **Description**: inserts the `:user` row before extraction, the `:assistant` row after narration/fallback (design §7 — transcript always complete).
- **Acceptance criteria**:
  - [ ] test asserts both rows persisted for a single turn (RED)
  - [ ] test asserts the fallback-regex path also persists both rows
- **Estimated lines**: +25 / -5
- **Depends on**: 6.3, 5.5

### Task 6.5 — LLM context window sourced from persisted history
- **Files**: `lib/meal_planner_api/generation/server.ex` (modify `session_context/1`); test extends `server_test.exs`
- **Type**: test-first
- **Description**: `session_context/1` queries `PlanningChatMessageRepo.list_recent_for_run/2` instead of relying solely on in-memory state (spec "Context survives a reconnect mid-negotiation").
- **Acceptance criteria**:
  - [ ] test asserts a 4th turn's context includes all 3 prior turns even after a simulated process restart for the same `generation_run_id` (RED)
- **Estimated lines**: +25 / -5
- **Depends on**: 6.3

### Task 6.6 — PR 6 checkpoint: reconnect-consistency test
- **Files**: `test/meal_planner_api/generation/chat_history_consistency_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: 3 turns → process teardown/restart for the same `generation_run_id` → 4th turn; asserts persisted-history-derived context matches the continuously-running-session result (spec "Session state and persisted history stay consistent").
- **Acceptance criteria**:
  - [ ] replaying persisted turns reproduces the same merged constraint set
- **Estimated lines**: +25 / -0
- **Depends on**: 6.4, 6.5

**PR 6 subtotal**: +175 added, -10 modified, 6 tasks. **Risk**: Low.

---

## PR 7 — Narration + full E2E checkpoint

**Goal**: read-only narration turn, infeasibility narration, channel wiring, and the design §11 acceptance scenario.
**Depends on**: PR 5 (parallel-safe with PR 6).

### Task 7.1 — `AI.narrate_plan/2`
- **Files**: `lib/meal_planner_api/ai.ex` (extend); `test/meal_planner_api/ai_test.exs` (extend)
- **Type**: test-first
- **Description**: `generate_text/2` fed only already-solved `proposal_json` data plus accumulated constraint/assumption context. Return type `{:ok, String.t()}` — type-level guarantee against writing back into plan data (spec "Narration is strictly read-only over solved output").
- **Acceptance criteria**:
  - [ ] test asserts the prompt contains only serialized solved data + context (RED)
  - [ ] test asserts a client error returns `{:error, _}`, never raises
- **Estimated lines**: +35 / -0
- **Depends on**: none

### Task 7.2 — Narration states defaulted-servings and budget/macro tradeoff assumptions
- **Files**: `lib/meal_planner_api/ai.ex` (extend prompt-building helper); test extends `ai_test.exs`
- **Type**: test-first
- **Description**: flags defaulted (not explicitly overridden) servings and any solver-relaxed constraint in the prompt context (spec "Unspecified servings assumption is narrated" / "Budget/macro conflict tradeoff is narrated").
- **Acceptance criteria**:
  - [ ] test asserts a flagged defaulted-servings note for non-overridden slots (RED)
  - [ ] test asserts a relaxed-constraint note when the solver had to relax one
- **Estimated lines**: +30 / -0
- **Depends on**: 7.1

### Task 7.3 — `AI.narrate_infeasibility/2`
- **Files**: `lib/meal_planner_api/ai.ex` (extend); `lib/meal_planner_api/generation/server.ex` (modify `handle_optimization_error/3`); test extends `ai_test.exs`, `server_test.exs`
- **Type**: test-first
- **Description**: same read-only contract as 7.1, fed the constraint context behind `no_optimal_solution`; `handle_optimization_error/3` (today only broadcasts the reason atom) gains the narration text in its broadcast (design §6, "gap the proposal doesn't cover").
- **Acceptance criteria**:
  - [ ] test asserts an infeasible solve still broadcasts the reason atom (regression) AND a plain-language narration (RED)
- **Estimated lines**: +35 / -5
- **Depends on**: 7.1

### Task 7.4 — Soft iteration-count nudge in narration
- **Files**: `lib/meal_planner_api/ai.ex` (extend); test extends `ai_test.exs`
- **Type**: test-first
- **Description**: once `state.solve_count >= @soft_iteration_threshold` (config, default `5`), the prompt context includes the count so narration appends a gentle nudge; never blocks iteration.
- **Acceptance criteria**:
  - [ ] test asserts `solve_count: 6` produces a nudge-including context (RED — spec "Threshold reached mid-negotiation")
  - [ ] test asserts `solve_count: 2` produces no nudge (spec "Threshold not yet reached")
- **Estimated lines**: +20 / -0
- **Depends on**: 7.1, 5.3

### Task 7.5 — `PlanningChannel` broadcasts gain `narration`
- **Files**: `lib/meal_planner_api_web/channels/planning_channel.ex` (modify); `lib/meal_planner_api/generation/server.ex` (modify `persist_proposal_result/4` — synchronous `narrate_plan/2` call before broadcast, per design §6 scope reduction); `test/meal_planner_api_web/channels/planning_channel_test.exs` (extend)
- **Type**: test-first
- **Description**: additive `narration` field on `proposal_ready`/`proposal_update`. Narration failure broadcasts `narration: nil`, never blocks the event (spec "Narration failure never blocks the proposal").
- **Acceptance criteria**:
  - [ ] test asserts a successful solve's broadcast includes non-nil `narration` (RED)
  - [ ] test asserts a forced narration error still broadcasts with `narration: nil`
  - [ ] test asserts a client reading only pre-existing fields is unaffected (spec "Client ignoring narration is unaffected")
- **Estimated lines**: +40 / -10
- **Depends on**: 7.1, 7.3

### Task 7.6 — Narration read-only guarantee test
- **Files**: `test/meal_planner_api/generation/narration_readonly_test.exs` (new)
- **Type**: dedicated test (checkpoint)
- **Description**: byte-identical `proposal_json` snapshot compare before/after the narration call (spec "Narration describes an existing plan without side effects").
- **Acceptance criteria**:
  - [ ] `proposal_json` byte-identical pre/post narration
- **Estimated lines**: +20 / -0
- **Depends on**: 7.5

### Task 7.7 — Final checkpoint: full "Sunday for 10" E2E (design §11)
- **Files**: `test/meal_planner_api/generation/sunday_for_ten_e2e_test.exs` (new)
- **Type**: dedicated test (checkpoint, E2E)
- **Description**: exercises design §11 steps 1–10 in one continuous run: generate → chat "Domingo cocinamos para 10, el resto de la semana para 4" → extraction → changeset acceptance → payload `requested_servings` (10 Sunday / 4 default) → re-solved `proposal_json` matching values, Sunday's objective contribution exactly `2.5×` a same-recipe weekday slot (not `recipe.servings`-scaled) → confirm → `ScheduledMeal.servings` correct per day → shopping items `2.5×` for shared ingredients → narration references "10"/"4" with byte-identical `proposal_json` → circuit opens after 3 forced failures, 4th turn falls back cleanly → an infeasible combination broadcasts `generation_error` plus a plain-language narration.
- **Acceptance criteria**:
  - [ ] all 10 design §11 assertions pass end-to-end in one test run
- **Estimated lines**: +75 / -0
- **Depends on**: PR 1–7 (final gate before merge readiness)

**PR 7 subtotal**: +255 added, -15 modified, 7 tasks. **Risk**: Low.

---

## Task Count Summary

| PR | Tasks | LOC (est.) | Risk |
|----|-------|-----------|------|
| 1 | 7 | +240 / -13 | Low |
| 2 | 6 | +210 / -30 | Low |
| 3 | 5 | +125 / -20 | Low |
| 4 | 9 | +275 / -5 | Low |
| 5 | 8 | +240 / -27 | Low |
| 6 | 6 | +175 / -10 | Low |
| 7 | 7 | +255 / -15 | Low |
| **Total** | **48** | **+1,520 / -120 (~1,400 net)** | **Low per slice; chained delivery** |

## Deviation Notes

- Design §9's 7-PR scope boundaries are followed exactly — no PR was merged, split, or reordered. Within each PR, this breakdown adds a few shared-helper tasks design's prose calls for but doesn't list as separate line items: `ServingsPolicy` (1.3), the `scaling_factor/2` helper (3.4), and dedicated checkpoint tests per PR (1.7, 2.3, 3.5, 5.8, 6.6, 7.6/7.7) — refinements within the stated scope, not restructuring.
- Bottom-up task-level LOC sums (~1,400 net) run lower than design §9's top-of-funnel forecast (~1,980 across the same 7 PRs); both agree every slice stays well under the 400-line budget, so no split decision changes.
- PR 3 grounding: `shopping_service.ex` has a second raw-copy site, `build_items_from_recipes/3` (ad-hoc/checkout recipe-id flow, no `ScheduledMeal` to scale by) — left out of scope; flagged as an open question below rather than silently expanding PR 3.

## Open Questions for `sdd-apply`

1. Should `build_items_from_recipes/3`'s ad-hoc shopping-list path (no `ScheduledMeal` context) get a follow-up decision on servings scaling, or is base-recipe-servings (1x) the correct behavior indefinitely for that flow?
2. Confirm `gemini-2.5-flash-lite` accepts `responseSchema` against the live API before PR 4 lands (design's open question — `:gemini_structured_output_enabled` is the fallback toggle if not).
3. Migration timestamps in tasks 1.1 (`20260713100000`) and 6.1 (`20260714090000`) are placeholders — confirm no collision with any migration landed on `fix/planning-pipeline-plumbing` before generating the real files.
4. PR 4's bottom-up estimate (~270 net) doesn't need the 4a/4b split design flagged as possible — confirm at apply time once the real diff is drafted.

## Verification (per PR)

| PR | Command sequence | Pass criteria |
|---|---|---|
| 1 | `mix ecto.migrate && mix test test/meal_planner_api/persistence/planning/ test/meal_planner_api/generation/servings_roundtrip_test.exs && mix precommit` | Migration applies; servings round-trip GREEN |
| 2 | Python scaling test harness + `mix test test/meal_planner_api/optimization/ && mix precommit` | Property test (2.3) passes across `1..20`; payload/adapter tests GREEN |
| 3 | `mix test test/meal_planner_api/services/shopping_service_test.exs test/meal_planner_api/services/cooking_service_test.exs test/meal_planner_api/services/shopping_inventory_scaling_test.exs && mix precommit` | 2.5x ratio holds on both shopping and inventory paths |
| 4 | `mix test test/meal_planner_api/ai/ test/meal_planner_api/persistence/planning/constraint_delta_test.exs && mix precommit` | Sanitize + changeset gate GREEN; additive, no wiring regressions |
| 5 | `mix test test/meal_planner_api/generation/ test/meal_planner_api/ai/circuit_breaker_test.exs && mix precommit` | Circuit breaker + fallback GREEN; regex UX regression-free |
| 6 | `mix ecto.migrate && mix test test/meal_planner_api/data/planning_chat_message_repo_test.exs test/meal_planner_api/generation/chat_history_consistency_test.exs && mix precommit` | Context survives reconnect; cross-account read impossible |
| 7 | `mix test test/meal_planner_api_web/channels/planning_channel_test.exs test/meal_planner_api/generation/sunday_for_ten_e2e_test.exs && mix precommit` | Full design §11 E2E GREEN |

## References

- **Proposal**: `meal_planner_api/openspec/changes/conversational-ai-planning/proposal.md`
- **Design**: `meal_planner_api/openspec/changes/conversational-ai-planning/design.md`
- **Specs (4)**: `specs/variable-servings.md`, `specs/conversational-constraint-extraction.md`, `specs/plan-narration.md`, `specs/planning-chat-history.md`
- **Prerequisite branch**: `fix/planning-pipeline-plumbing` (merged baseline, not re-scoped)
- **API OpenSpec config**: `meal_planner_api/openspec/config.yaml` — `strict_tdd: true`, `max_changed_lines: 400`
- **Grounding reads**: `lib/meal_planner_api/generation/server.ex`, `services/generation_service.ex`, `services/planning_chat_service.ex`, `services/shopping_service.ex`, `services/cooking_service.ex`, `optimization/payload_adapter.ex`, `ai/client.ex`, `ai/gemini_client.ex`, `ai/mock_client.ex`, `persistence/planning/scheduled_meal.ex`, `optimizador.py`
- **Tone reference**: `meal_planner_api/openspec/changes/phase-a-tenancy-refactor/tasks.md`

## Next Step

Ready for `sdd-apply` with PR 1 as the first slice (feature-branch-chain: PR 1 → tracker/`fix/planning-pipeline-plumbing`; PR 2/3/4 → PR 1 branch, parallel-safe; PR 5 → PR 2 + PR 4; PR 6/7 → PR 5 branch, parallel-safe). Resolve the open questions above (especially #2, the Gemini `responseSchema` live-API confirmation) before PR 4 lands.
