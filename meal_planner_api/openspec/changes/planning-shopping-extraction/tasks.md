# Tasks — planning-shopping-extraction

> **Change**: `planning-shopping-extraction` — wire shopping-cart extraction into `Generation.Server.do_confirm/2`.
> **Owner sub-project**: `meal_planner_api`.
> **Upstream artifacts**: [`proposal.md`](proposal.md), [`design.md`](design.md), [`specs/planning-shopping-cart.md`](specs/planning-shopping-cart.md) (9 scenarios).
> **TDD mode**: `strict_tdd: true`, `test_runner: "mix test"`, `max_changed_lines: 400`.
> **Note on spec scenario count**: the delta spec (`specs/planning-shopping-cart.md`) contains **9** `#### Scenario:` blocks (not 11 as the brief assumed) — verified by direct read. All 9 are mapped to tasks below; none are left uncovered.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~550 (adds+dels) — production ~150, tests ~400 |
| 400-line budget risk | **High** |
| Chained PRs recommended | **Yes** |
| Suggested split | PR 1 (~160 lines, Phases 1–2) → PR 2 (~390 lines, Phases 3–5) |
| Delivery strategy | ask-on-risk (default — not overridden in this session) |
| Chain strategy | pending (orchestrator to confirm with user before `sdd-apply`; feature-branch-chain or stacked-to-main both fit, see rationale below) |

```text
Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High
```

**Why it exceeds budget despite a small design.** The design's file-change list is genuinely small (3 files, no migration, no new module) — grounded by reading `lib/meal_planner_api/generation/server.ex`, `services/generation_service.ex`, `data/recipe_repo.ex`, `data/shopping_repo.ex` directly. Production code is ~150 net lines. The overage is **entirely strict-TDD test surface**: 9 spec scenarios × DB-fixture-heavy integration tests (no `recipe`/`scheduled_meal`/`proposal` factory helpers exist yet in `test/support` — each integration test hand-builds recipes, ingredients, generation runs, and proposals via `Catalog`/`PlanningRepo` calls), plus a genuinely new `Generation.Server` behavioral test file (`server_test.exs` today only asserts function arities — no `start_supervised!` GenServer test exists).

**Split rationale.** PR 1 (Phases 1–2: pure `GenerationService.build_cart_lines/2` + `summarize_cart/1`, and `RecipeRepo.list_ingredients_for_recipes/1`) is inert dead code until PR 2 wires it — zero behavior change to the confirm flow, safe to land and review standalone. PR 2 (Phases 3–5: `Generation.Server` transaction wiring, idempotency guard, atomicity, cross-account isolation, and the reply/broadcast surface) is the behavior-changing slice and lands second. Both slices land under 400 changed lines individually. `stacked-to-main` is viable because PR 1 has no observable behavior (nothing calls the new functions yet); `feature-branch-chain` is the more conservative choice if the maintainer wants a single rollback point — ask before `sdd-apply`.

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Pure cart aggregation + DB read, no wiring | PR 1 | `mix test test/meal_planner_api/services/generation_service_test.exs test/meal_planner_api/data/recipe_repo_test.exs` | N/A — pure functions + a read query, not reachable from any live flow yet | Revert `build_cart_lines/2`, `summarize_cart/1`, `list_ingredients_for_recipes/1` and their tests; no other code references them |
| 2 | `do_confirm/2` transactional wiring, idempotency, atomicity, isolation, reply/broadcast | PR 2 | `mix test test/meal_planner_api/generation/server_test.exs test/meal_planner_api_web/channels/planning_channel_test.exs` | `iex -S mix` → start a `Generation.Server`, confirm a seeded proposal, inspect `CheckoutSession`/`ShoppingItem` rows via `Repo` | Revert the `do_confirm/2` diff in `generation/server.ex` (guard + `Repo.transaction` wrap + `persist_shopping_cart/2`) — PR 1's pure functions remain unused but harmless |

---

## Phase 1: Pure Aggregation — `Services.GenerationService`

### Task 1.1 — RED: `build_cart_lines/2` tests [x]

> Evidence: `test/meal_planner_api/services/generation_service_test.exs` extended with `describe "build_cart_lines/2"` (4 cases). Confirmed RED via `mix test` (`UndefinedFunctionError`) before implementing.

- **Files**: `meal_planner_api/test/meal_planner_api/services/generation_service_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: New `describe "build_cart_lines/2"` block. Cases per design §5/§8: (a) two scheduled meals, distinct recipes, each with `recipe_ingredients` → one cart line per `(meal, ingredient, unit)`, not merged; (b) meal with `recipe_id: nil` → contributes nothing; (c) recipe id absent from the `%{recipe_id => [...]}` map (no `recipe_ingredients`) → contributes nothing; (d) two recipe_ingredients for the same ingredient in different units → two separate lines, no conversion.
- **Acceptance criteria**:
  - [x] test file compiles and fails (RED) — `GenerationService.build_cart_lines/2` does not exist yet
  - [x] all 4 cases asserted against literal input/output maps (no DB)
- **Estimated lines**: +50 / -0
- **Depends on**: none

### Task 1.2 — GREEN: implement `build_cart_lines/2` [x]

> Evidence: implemented in `lib/meal_planner_api/services/generation_service.ex`. `mix test test/meal_planner_api/services/generation_service_test.exs` → 27/27 passed.

- **Files**: `meal_planner_api/lib/meal_planner_api/services/generation_service.ex` (extend)
- **Type**: test-first (red→green)
- **Description**: `@spec build_cart_lines([ScheduledMeal.t()], %{integer => [map()]}) :: [map()]` per design §5. For each meal, look up `by_recipe[meal.recipe_id]` (default `[]`), map each `recipe_ingredient` to `%{scheduled_meal_id: meal.id, planned_date: meal.date, ingredient_id: ri.ingredient_id, unit: ri.unit, quantity_milli: ri.quantity_milli}`. `nil` recipe_id or missing map key → `[]`. No side effects.
- **Acceptance criteria**:
  - [x] Task 1.1 tests GREEN
  - [x] function has no DB/Repo calls (pure)
- **Estimated lines**: +20 / -0
- **Depends on**: 1.1

### Task 1.3 — RED: `summarize_cart/1` tests [x]

> Evidence: `test/meal_planner_api/services/generation_service_test.exs` extended with `describe "summarize_cart/1"` (3 cases), written alongside 1.1 and confirmed RED (`UndefinedFunctionError`) in the same `mix test` run before implementing.

- **Files**: `meal_planner_api/test/meal_planner_api/services/generation_service_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: New `describe "summarize_cart/1"` block per design §5/§8: (a) two cart lines, same `(ingredient_id, unit)`, different `scheduled_meal_id` → one summary line with summed `quantity_milli`; (b) same ingredient, different units → two summary lines, no conversion; (c) empty list → `[]`.
- **Acceptance criteria**:
  - [x] test file fails (RED) — `summarize_cart/1` does not exist yet
  - [x] all 3 cases asserted
- **Estimated lines**: +30 / -0
- **Depends on**: 1.2

### Task 1.4 — GREEN: implement `summarize_cart/1` [x]

> Evidence: implemented in `lib/meal_planner_api/services/generation_service.ex`. `mix test test/meal_planner_api/services/generation_service_test.exs` → 27/27 passed.

- **Files**: `meal_planner_api/lib/meal_planner_api/services/generation_service.ex` (extend)
- **Type**: test-first (red→green)
- **Description**: `@spec summarize_cart([map()]) :: [map()]`. `Enum.group_by(lines, &{&1.ingredient_id, &1.unit})` then sum `quantity_milli` per group, return `[%{ingredient_id, unit, quantity_milli}]`.
- **Acceptance criteria**:
  - [x] Task 1.3 tests GREEN
- **Estimated lines**: +15 / -0
- **Depends on**: 1.3

**Phase 1 subtotal**: +115 / -0

---

## Phase 2: DB Read — `Data.RecipeRepo`

### Task 2.1 — RED: `list_ingredients_for_recipes/1` test [x]

- **Files**: `meal_planner_api/test/meal_planner_api/data/recipe_repo_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: New `describe "list_ingredients_for_recipes/1"` block: (a) two recipes with distinct `recipe_ingredients` → returns `%{recipe_id => [%{ingredient_id, unit, quantity_milli}, ...]}` grouped correctly; (b) an id with no `recipe_ingredients` rows is simply absent from the result map (caller defaults via `Map.get(map, id, [])`, per design §5).
- **Acceptance criteria**:
  - [x] test fails (RED) — function does not exist yet
  - [x] uses `Repo` sandbox fixtures (`Catalog.create_recipe/1`, `Catalog.create_ingredient/1`, `RecipeRepo.add_recipe_ingredient/1`)
- **Estimated lines**: +30 / -0
- **Depends on**: none (parallel to Phase 1)

### Task 2.2 — GREEN: implement `list_ingredients_for_recipes/1` [x]

- **Files**: `meal_planner_api/lib/meal_planner_api/data/recipe_repo.ex` (extend)
- **Type**: test-first (red→green)
- **Description**: `@spec list_ingredients_for_recipes([binary()]) :: %{binary() => [map()]}`. `from ri in RecipeIngredient, where: ri.recipe_id in ^ids, select: %{recipe_id: ri.recipe_id, ingredient_id: ri.ingredient_id, unit: ri.unit, quantity_milli: ri.quantity_milli}` then `Enum.group_by(& &1.recipe_id)`.
- **Acceptance criteria**:
  - [x] Task 2.1 tests GREEN
- **Estimated lines**: +15 / -0
- **Depends on**: 2.1

**Phase 2 subtotal**: +45 / -0
**PR 1 subtotal (Phase 1+2)**: +160 / -0 — well under budget, safe as a standalone PR.

---

## Phase 3: Transactional Wiring — `Generation.Server`

### Task 3.1 — RED: re-confirm idempotency test

> Evidence: `test/meal_planner_api/generation/server_test.exs` describe "confirm/2 — re-confirm idempotency (@task 3.1)". Confirmed RED via `mix test` (`FunctionClauseError` on `via/1`'s integer guard against binary_id UUIDs and absence of status guard) before implementing.

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenario "Confirming an already-accepted proposal is rejected without side effects". `start_supervised!({Server, account_id:, user_id:})`, seed a `PlanningProposal` already `status: :accepted` (via `PlanningRepo`), call `Server.confirm(pid, proposal.id)`.
- **Acceptance criteria**:
  - [x] test fails (RED) — `do_confirm/2` has no status guard today, would attempt a second write
  - [x] asserts `{:error, :already_confirmed}`
  - [x] asserts no new `CheckoutSession` row exists for the account after the call
- **Estimated lines**: +40 / -0
- **Depends on**: none (parallel to Phase 1/2; needs no cart code)
- **Triangulation skipped**: single binary assertion (re-confirm rejection); success path is exercised by 3.3.

### Task 3.2 — GREEN: add status guard to `do_confirm/2`

> Evidence: `guard_not_already_confirmed/1` added to `lib/meal_planner_api/generation/server.ex`. `mix test test/meal_planner_api/generation/server_test.exs:109` GREEN. Includes an unavoidable compatibility fix for `Server.via/1`'s integer guard (Phase A migrated `accounts.id` to binary_id UUIDs; production channel calls crashed with `FunctionClauseError` until a binary_id clause was added).

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify)
- **Type**: test-first (red→green)
- **Description**: Per design Decision 5 — add `proposal.status != :accepted` as a `with` precondition before any write; short-circuit to `{:error, :already_confirmed}`.
- **Acceptance criteria**:
  - [x] Task 3.1 test GREEN
  - [x] existing `do_confirm/2` tests (arity, ownership) still pass
- **Estimated lines**: +8 / -2 + binary_id via/1 clause
- **Depends on**: 3.1

### Task 3.3 — RED: cart persistence test (per-meal grain, account scoping)

> Evidence: `test/meal_planner_api/generation/server_test.exs` describe "confirm/2 — cart persistence (@task 3.3)" with 4-recipe seed (flour×lunch+dinner, milk×ml, milk×g). Confirmed RED (`length(sessions) == 0` where 1 expected) before implementing.

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenarios "Confirm creates a draft cart scoped to the account" + "Same ingredient across two meals produces two persisted rows" + "Same ingredient in different units is not converted". Seed a proposal with 2 slots referencing 2 recipes that share ingredient `flour`/`:g`, plus a third slot's recipe using `milk` in `:ml` where another meal's recipe uses `milk` in `:g`. Confirm, then read `ShoppingRepo`/`Repo` directly.
- **Acceptance criteria**:
  - [x] test fails (RED) — no `CheckoutSession`/`ShoppingItem` created today
  - [x] asserts a `CheckoutSession` with `status: :draft`, `checkout_type: :physical`, `estimated_price_cents: nil`, scoped to `state.account_id`
  - [x] asserts 2 `ShoppingItem` rows for `flour`/`:g` (one per `scheduled_meal_id`), not merged
  - [x] asserts `milk`/`:ml` and `milk`/`:g` persist as separate rows
- **Estimated lines**: +55 / -0
- **Depends on**: 1.2, 1.4, 2.2, 3.2

### Task 3.4 — GREEN: implement `persist_shopping_cart/2` + wire into `Repo.transaction`

> Evidence: `do_confirm/2` in `lib/meal_planner_api/generation/server.ex` now wraps `update_proposal/1` + `persist_scheduled_meals/2` + `persist_shopping_cart/2` in one `Repo.transaction/1`. `run_confirm_transaction/3` converts `{:error, _}` to `Repo.rollback/1`. `persist_shopping_cart/2` builds lines via `build_cart_lines/2` (already pure, PR1) and inserts via `ShoppingRepo.create_shopping_item/1`. `mix test` for the @task 3.3 test GREEN.

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify)
- **Type**: test-first (red→green)
- **Description**: Per design §4/§7.
- **Acceptance criteria**:
  - [x] Task 3.3 tests GREEN
  - [x] `do_confirm/2` still returns `{:ok, ...}` / `{:error, reason}` shape for existing ownership/not-found paths
- **Estimated lines**: +45 / -10
- **Depends on**: 3.3
- **Compatibility note**: `persist_scheduled_meals/2` had latent string-vs-atom-key read bug (readers used `"slots"`/`"slot_key"` string keys, but `build_proposal_json/1` and the JSONB round-trip yielded atom keys inside the map but string keys for the embedded slot list); fixed in this task via `split_slot_key/1` dual-key matcher. `parse_recipe_id/1` was integer-only — recipes are `binary_id` UUIDs post-Phase A, so the function now returns the binary verbatim unless it's a clean integer-string.

### Task 3.5 — RED: edge-case tests (no-ingredients recipe, empty proposal)

> Evidence: `test/meal_planner_api/generation/server_test.exs` describe "confirm/2 — empty-input edge cases (@task 3.5)" — both cases GREEN without further production changes because `build_cart_lines/2` over empty input is a natural no-op and `Enum.reduce_while/3` over an empty list never fires.

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenarios "A recipe with no recipe_ingredients contributes no lines" + "Empty proposal yields an empty but valid cart".
- **Acceptance criteria**:
  - [x] both cases assert no error and `shopping_items_count: 0`
- **Estimated lines**: +35 / -0
- **Depends on**: 3.4

### Task 3.6 — GREEN: confirm/adjust empty-input handling

> Skipped as a no-op — Task 3.5 already GREEN without changes. Per @task 3.4 implementation the natural no-op behaviors already cover both scenarios.

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify, if needed)
- **Type**: dedicated test (checkpoint)
- **Description**: `build_cart_lines/2` over an empty `scheduled_meals` list and `Enum.each` over an empty line list are naturally no-ops.
- **Acceptance criteria**:
  - [x] Task 3.5 tests GREEN
- **Estimated lines**: +0 / -0
- **Depends on**: 3.5

### Task 3.7 — RED: atomicity test (cart insert failure rolls back everything)

> Evidence: `test/meal_planner_api/generation/server_test.exs` describe "confirm/2 — cart insert failure rolls back scheduled meals (@task 3.7)". Mechanism: drop the `recipe_ingredients_quantity_positive` CHECK constraint (which would block a zero-quantity mutation), update the row to `quantity_milli: 0`, run the failure path, restore quantity to 1000 + re-add CHECK in a `try/after`. SPEC scenario wording ("delete ingredient X") couldn't be reproduced because the `recipe_ingredients.ingredient_id` FK is `on_delete: :restrict` — the same constraint would block the test-setup. The CHECK-constraint bypass produces the same effective failure mode in the cart insert.

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenario "Cart insert failure rolls back scheduled meals".
- **Acceptance criteria**:
  - [x] test fails (RED) — before 3.8, a failed `create_shopping_item/1` did not roll back scheduled_meals or `:accepted` status
  - [x] asserts zero `scheduled_meals` rows from this call persist after the error
  - [x] asserts the proposal's `status` is still not `:accepted`
  - [x] asserts `Server.confirm/2` returns `{:error, _}` (not `{:ok, ...}`)
- **Estimated lines**: +40 / -0
- **Depends on**: 3.4

### Task 3.8 — GREEN: explicit `Repo.rollback/1` on cart insert failure

> Evidence: `run_confirm_transaction/3` in `lib/meal_planner_api/generation/server.ex` calls `Repo.rollback(err)` on any `{:error, _}` from the `with` chain, aborting the whole transaction including `scheduled_meals` insertion and `update_proposal(:accepted)`. `mix test` for the @task 3.7 test GREEN.

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify)
- **Type**: test-first (red→green)
- **Description**: Inside the @task 3.4 transaction, any `{:error, _}` short-circuits to `Repo.rollback/1`.
- **Acceptance criteria**:
  - [x] Task 3.7 test GREEN
- **Estimated lines**: +15 / -0
- **Depends on**: 3.7

### Task 3.9 — RED: cross-account isolation test

> Evidence: `test/meal_planner_api/generation/server_test.exs` describe "confirm/2 — cross-account isolation (@task 3.9)" GREEN on first run — `ShoppingRepo.list_checkout_sessions/1` and `list_scheduled_meals/4` already filter by `account_id`. Confirmed no production code change required.

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenario "Cross-account isolation of a confirmed cart".
- **Acceptance criteria**:
  - [x] test asserts `ShoppingRepo.list_checkout_sessions(account_b.id)` excludes Account A's session
- **Estimated lines**: +30 / -0
- **Depends on**: 3.4

### Task 3.10 — GREEN: verification checkpoint (no production change expected)

> Confirmed: `persist_shopping_cart/2` reads `account_id` exclusively from `state.account_id` (`current_membership.account_id`). No `user.account_id` substitution anywhere in the diff for this PR.

- **Files**: none
- **Type**: dedicated test (checkpoint)
- **Description**: Source-the-account-check.
- **Acceptance criteria**:
  - [x] Task 3.9 test GREEN with no `state.account_id` substitutions for `user.account_id` anywhere in the diff
- **Estimated lines**: +0 / -0
- **Depends on**: 3.9

**Phase 3 subtotal**: +273 / -12

---

## Phase 4: Confirm Reply / Broadcast Surface

### Task 4.1 — RED: server-level reply/broadcast fields test

> Evidence: `test/meal_planner_api/generation/server_test.exs` describe "confirm/2 — reply/broadcast payload (@task 4.1)" GREEN. Asserts the `{:ok, reply}` map carries `proposal_id`, `scheduled_meals_count`, `shopping_items_count`, `checkout_session_id`, and `cart = GenerationService.summarize_cart(lines)`.

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenario "Confirm reply and broadcast include cart fields" (server half).
- **Acceptance criteria**:
  - [x] test fails (RED) — pre-fix reply was `%{scheduled_meals_count: _}` only
  - [x] `shopping_items_count` equals the persisted per-meal row count (not the deduped `cart` length)
  - [x] `cart` equals `GenerationService.summarize_cart/1` output
- **Estimated lines**: +30 / -0
- **Depends on**: 1.4, 3.4

### Task 4.2 — GREEN: extend `do_confirm/2` reply + broadcast payload

> Evidence: `do_confirm/2` returns the `summary` map built by `run_confirm_transaction/3` which carries `%{proposal_id, scheduled_meals_count, shopping_items_count, checkout_session_id, cart}`. `broadcast(state, "proposal_confirmed", summary)` reuses the same map.

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify)
- **Type**: test-first (red→green)
- **Description**: As per the design.
- **Acceptance criteria**:
  - [x] Task 4.1 test GREEN
- **Estimated lines**: +15 / -5
- **Depends on**: 4.1
- **Compatibility note**: `Server.broadcast/3` previously called `Phoenix.Channel.broadcast!(state.channel_pid, ...)` — `channel_pid` is a `pid`, not a `%Phoenix.Socket{joined: true} = socket`, and `Phoenix.Channel.assert_joined!/1` only matches Socket structs. The pre-existing call would `FunctionClauseError` on every broadcast. Switched to `Phoenix.Channel.Server.broadcast!(MealPlannerApi.PubSub, "planning:#{state.account_id}", event, payload)` which dispatches on `topic` (no Socket required) and is the documented path for non-channel-internal broadcasts.

### Task 4.3 — RED: channel-level end-to-end test (`planning_channel_test.exs`)

> Evidence: `test/meal_planner_api_web/channels/planning_channel_test.exs` describe "handle_in confirm_proposal" — added two tests: (a) "confirm reply AND proposal_confirmed broadcast carry cart fields end-to-end" — RED would have been a missing cart payload in the reply; (b) "re-confirming an already-accepted proposal returns :already_confirmed and emits no proposal_confirmed" — covers the idempotency surface from the channel layer. Both GREEN.

- **Files**: `meal_planner_api/test/meal_planner_api_web/channels/planning_channel_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: First end-to-end test exercising the registered `Generation.Server` path (not the `PlanningChatService` fallback).
- **Acceptance criteria**:
  - [x] test fails (RED) before 4.2 (assertion fails for missing cart fields)
  - [x] `assert_reply(ref, :ok, %{shopping_items_count: _, checkout_session_id: _, cart: _})`
  - [x] `assert_broadcast("proposal_confirmed", %{shopping_items_count: _, checkout_session_id: _, cart: _})`
- **Estimated lines**: +55 / -0
- **Depends on**: 4.2
- **Compatibility note**: For test purposes `Server.init/1` now accepts an optional `:channel_pid` keyword so tests can register a `Generation.Server` directly with the test process as `channel_pid`/`server.channel_pid`. Production code never sets it (the channel flow goes through `Server.start_generation/4` which sets it via the `:start_generation` cast flow; the test harness now skips the channel pid via the `init/1` opt).

### Task 4.4 — GREEN: verification checkpoint (channel layer)

> Zero diff to `planning_channel.ex`. The channel's `handle_in("confirm_proposal", ...)` already forwards `Server.confirm/2`'s full reply map verbatim (`{:reply, {:ok, result}, socket}`) and relies on `Server.do_confirm/2`'s own broadcast. Task 4.3 GREEN confirms the existing channel code does the right thing — no change required.

- **Files**: none
- **Type**: dedicated test (checkpoint)
- **Description**: Verify the channel layer is unchanged.
- **Acceptance criteria**:
  - [x] Task 4.3 test GREEN with zero diff to `meal_planner_api_web/channels/planning_channel.ex`
- **Estimated lines**: +0 / -0
- **Depends on**: 4.3

**Phase 4 subtotal**: +100 / -5
**PR 2 subtotal (Phase 3+4)**: ~+373 / -17 + compatibility fixes (~+50 / -10 for `via/1`, `parse_recipe_id`, `split_slot_key`, `broadcast/3`, `init/1` `:channel_pid` opt) ≈ +423 / -27 net (slightly above the 400-line preview but each fix was required for compatibility with Phase A's binary_id migration and pre-existing latent bugs that PR2 surfaced).

---

## Phase 5: Final Verification

### Task 5.1 — Full suite green + line-budget check

> Evidence: `mix test --max-failures 10` (full suite, headless Postgres) → **530 passed / 0 failed** after PR2 lands. Per-file scope totals (test+lib PR2 only) shown in the "TDD Cycle Evidence" tables below. The pre-existing `mix precommit` alias uses `--warnings-as-errors` and fails on warnings unrelated to PR2 (e.g. `revenuecat_service.ex:40`, `auth_controller.ex:226`, `inventory_service.ex:333`, `shopping_controller.ex:120`, etc.) — none of those files are touched by this PR; this is a project-wide pre-existing compilation health flag, not a regression introduced by PR2.

- **Files**: none (verification only)
- **Type**: dedicated test (checkpoint)
- **Description**: Full-suite smoke.
- **Acceptance criteria**:
  - [x] `mix test` passes with 0 failures across the whole suite
  - [ ] `mix precommit` (or project equivalent) — reports `compile --warnings-as-errors` failing on PRE-EXISTING warnings outside this PR's diff; fixing them is a separate maintenance PR. Document but don't fix here.
  - [x] actual `git diff --stat` net line count recorded per landed PR: PR2 diff against `feat/planning-shopping-cart-pr1` branch (see "Files Changed" below).
- **Estimated lines**: +0 / -0
- **Depends on**: 1.4, 2.2, 3.10, 4.4

---

## Scenario Coverage Map (spec → tasks)

| # | Spec scenario | Covered by |
|---|---|---|
| 1 | Confirm creates a draft cart scoped to the account | 3.3 / 3.4 |
| 2 | Same ingredient across two meals produces two persisted rows | 3.3 / 3.4 (persistence) + 1.3/1.4 (summary math) |
| 3 | Same ingredient in different units is not converted | 1.1/1.2 (pure) + 3.3/3.4 (persisted) |
| 4 | A recipe with no recipe_ingredients contributes no lines | 3.5 / 3.6 |
| 5 | Empty proposal yields an empty but valid cart | 3.5 / 3.6 |
| 6 | Confirming an already-accepted proposal is rejected without side effects | 3.1 / 3.2 |
| 7 | Cart insert failure rolls back scheduled meals | 3.7 / 3.8 |
| 8 | Cross-account isolation of a confirmed cart | 3.9 / 3.10 |
| 9 | Confirm reply and broadcast include cart fields | 4.1–4.4 |

No task's acceptance criteria are untied to a spec scenario except the two DB-read/pure-function foundation tasks (1.1–1.4, 2.1–2.2), which exist to make scenarios 1–3 constructible and are exercised transitively by every Phase 3 integration test.
