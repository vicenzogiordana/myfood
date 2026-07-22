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

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenario "Confirming an already-accepted proposal is rejected without side effects". `start_supervised!({Server, account_id:, user_id:})`, seed a `PlanningProposal` already `status: :accepted` (via `PlanningRepo`), call `Server.confirm(pid, proposal.id)`.
- **Acceptance criteria**:
  - [ ] test fails (RED) — `do_confirm/2` has no status guard today, would attempt a second write
  - [ ] asserts `{:error, :already_confirmed}`
  - [ ] asserts no new `CheckoutSession` row exists for the account after the call
- **Estimated lines**: +40 / -0
- **Depends on**: none (parallel to Phase 1/2; needs no cart code)

### Task 3.2 — GREEN: add status guard to `do_confirm/2`

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify)
- **Type**: test-first (red→green)
- **Description**: Per design Decision 5 — add `proposal.status != :accepted` as a `with` precondition before any write; short-circuit to `{:error, :already_confirmed}`.
- **Acceptance criteria**:
  - [ ] Task 3.1 test GREEN
  - [ ] existing `do_confirm/2` tests (arity, ownership) still pass
- **Estimated lines**: +8 / -2
- **Depends on**: 3.1

### Task 3.3 — RED: cart persistence test (per-meal grain, account scoping)

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenarios "Confirm creates a draft cart scoped to the account" + "Same ingredient across two meals produces two persisted rows" + "Same ingredient in different units is not converted". Seed a proposal with 2 slots referencing 2 recipes that share ingredient `flour`/`:g`, plus a third slot's recipe using `milk` in `:ml` where another meal's recipe uses `milk` in `:g`. Confirm, then read `ShoppingRepo`/`Repo` directly.
- **Acceptance criteria**:
  - [ ] test fails (RED) — no `CheckoutSession`/`ShoppingItem` created today
  - [ ] asserts a `CheckoutSession` with `status: :draft`, `checkout_type: :physical`, `estimated_price_cents: nil`, scoped to `state.account_id`
  - [ ] asserts 2 `ShoppingItem` rows for `flour`/`:g` (one per `scheduled_meal_id`), not merged
  - [ ] asserts `milk`/`:ml` and `milk`/`:g` persist as separate rows
- **Estimated lines**: +55 / -0
- **Depends on**: 1.2, 1.4, 2.2, 3.2

### Task 3.4 — GREEN: implement `persist_shopping_cart/2` + wire into `Repo.transaction`

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify)
- **Type**: test-first (red→green)
- **Description**: Per design §4/§7. Wrap `update_proposal(:accepted)` + `persist_scheduled_meals/2` + new `persist_shopping_cart/2` in one `Repo.transaction/1`. `persist_shopping_cart(scheduled_meals, state)`: `RecipeRepo.list_ingredients_for_recipes/1` (recipe ids from `scheduled_meals`) → `GenerationService.build_cart_lines/2` → `ShoppingRepo.create_checkout_session/1` (`account_id: state.account_id, status: :draft, checkout_type: :physical`) → `Enum.each` lines → `ShoppingRepo.create_shopping_item/1` (line attrs + `account_id` + `checkout_session_id`).
- **Acceptance criteria**:
  - [ ] Task 3.3 tests GREEN
  - [ ] `do_confirm/2` still returns `{:ok, ...}` / `{:error, reason}` shape for existing ownership/not-found paths
- **Estimated lines**: +45 / -10
- **Depends on**: 3.3

### Task 3.5 — RED: edge-case tests (no-ingredients recipe, empty proposal)

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenarios "A recipe with no recipe_ingredients contributes no lines" + "Empty proposal yields an empty but valid cart". (a) proposal with one slot whose recipe has zero `recipe_ingredients` → confirm succeeds, 0 `ShoppingItem` rows, not an error; (b) proposal with no slots → confirm succeeds, draft `CheckoutSession` created, `shopping_items_count: 0`.
- **Acceptance criteria**:
  - [ ] tests fail or pass unexpectedly (RED) if not yet correctly handled — write first, confirm against pre-3.4 code path if run in isolation, then against 3.4 GREEN
  - [ ] both cases assert no error and `shopping_items_count: 0`
- **Estimated lines**: +35 / -0
- **Depends on**: 3.4

### Task 3.6 — GREEN: confirm/adjust empty-input handling

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify, if needed)
- **Type**: test-first (red→green)
- **Description**: `build_cart_lines/2` over an empty `scheduled_meals` list and `Enum.each` over an empty line list are naturally no-ops; this task exists to make the RED test in 3.5 pass and to fix any edge case it surfaces (e.g. `CheckoutSession` still created even with zero lines).
- **Acceptance criteria**:
  - [ ] Task 3.5 tests GREEN
- **Estimated lines**: +5 / -0
- **Depends on**: 3.5

### Task 3.7 — RED: atomicity test (cart insert failure rolls back everything)

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenario "Cart insert failure rolls back scheduled meals". Seed a proposal whose scheduled meal's recipe has a `recipe_ingredient` referencing ingredient X; **delete ingredient X's row** right before calling `Server.confirm/2` so the `ShoppingItem` insert hits `foreign_key_constraint(:ingredient_id)` and fails.
- **Acceptance criteria**:
  - [ ] test fails (RED) — before 3.8, a failed `create_shopping_item/1` does not roll back the already-inserted `scheduled_meals` row or the `:accepted` proposal status
  - [ ] asserts zero `scheduled_meals` rows from this call persist after the error
  - [ ] asserts the proposal's `status` is still not `:accepted`
  - [ ] asserts `Server.confirm/2` returns `{:error, _}` (not `{:ok, ...}`)
- **Estimated lines**: +40 / -0
- **Depends on**: 3.4

### Task 3.8 — GREEN: explicit `Repo.rollback/1` on cart insert failure

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify)
- **Type**: test-first (red→green)
- **Description**: Inside `persist_shopping_cart/2`, any `{:error, changeset}` from `create_checkout_session/1` or `create_shopping_item/1` calls `Repo.rollback(reason)`, which aborts the whole `Repo.transaction/1` from Task 3.4 (scheduled meals + proposal status included).
- **Acceptance criteria**:
  - [ ] Task 3.7 test GREEN
- **Estimated lines**: +15 / -0
- **Depends on**: 3.7

### Task 3.9 — RED: cross-account isolation test

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenario "Cross-account isolation of a confirmed cart". Membership A on Account A confirms a proposal (creates `CheckoutSession`/`ShoppingItem` rows). Assert `ShoppingRepo.list_checkout_sessions(account_b.id)` and `ShoppingRepo.list_shopping_items/1` scoped to Account B's own sessions never surface Account A's rows.
- **Acceptance criteria**:
  - [ ] test asserts `ShoppingRepo.list_checkout_sessions(account_b.id)` excludes Account A's session (should already be GREEN given `account_id` scoping — this test is a regression guard, not expected to require new production code)
- **Estimated lines**: +30 / -0
- **Depends on**: 3.4

### Task 3.10 — GREEN: verification checkpoint (no production change expected)

- **Files**: none expected; `meal_planner_api/lib/meal_planner_api/generation/server.ex` (only if 3.9 surfaces a real scoping bug)
- **Type**: dedicated test (checkpoint)
- **Description**: `persist_shopping_cart/2` (Task 3.4) always sources `account_id` from `state.account_id` (`current_membership.account_id`, never `user.account_id`, per proposal success criteria and design §2). If Task 3.9 is unexpectedly RED, fix the scoping source here; otherwise this task only confirms GREEN and closes the loop.
- **Acceptance criteria**:
  - [ ] Task 3.9 test GREEN with no `state.account_id` substitutions for `user.account_id` anywhere in the diff
- **Estimated lines**: +0 / -0
- **Depends on**: 3.9

**Phase 3 subtotal**: +273 / -12

---

## Phase 4: Confirm Reply / Broadcast Surface

### Task 4.1 — RED: server-level reply/broadcast fields test

- **Files**: `meal_planner_api/test/meal_planner_api/generation/server_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Maps to spec scenario "Confirm reply and broadcast include cart fields" (server half). Register a fake `channel_pid` (a test process using `Phoenix.Channel.broadcast!` interception, or assert via `PlanningRepo`/direct broadcast capture per project's existing `broadcast/3` helper convention). Confirm a proposal producing cart lines; assert both the `{:ok, result}` reply and the `"proposal_confirmed"` broadcast payload carry `shopping_items_count`, `checkout_session_id`, and `cart` (`[%{ingredient_id, unit, quantity_milli}]`), alongside the existing `scheduled_meals_count`.
- **Acceptance criteria**:
  - [ ] test fails (RED) — today's reply/broadcast only has `scheduled_meals_count`
  - [ ] `shopping_items_count` equals the persisted per-meal row count (not the deduped `cart` length)
  - [ ] `cart` equals `GenerationService.summarize_cart/1` output
- **Estimated lines**: +30 / -0
- **Depends on**: 1.4, 3.4

### Task 4.2 — GREEN: extend `do_confirm/2` reply + broadcast payload

- **Files**: `meal_planner_api/lib/meal_planner_api/generation/server.ex` (modify)
- **Type**: test-first (red→green)
- **Description**: After `persist_shopping_cart/2` returns the created `checkout_session` + `lines`, compute `cart = GenerationService.summarize_cart(lines)` and add `shopping_items_count: length(lines)`, `checkout_session_id: checkout_session.id`, `cart: cart` to both the `broadcast(state, "proposal_confirmed", %{...})` map and the `{:ok, %{...}}` return value.
- **Acceptance criteria**:
  - [ ] Task 4.1 test GREEN
- **Estimated lines**: +15 / -5
- **Depends on**: 4.1

### Task 4.3 — RED: channel-level end-to-end test (`planning_channel_test.exs`)

- **Files**: `meal_planner_api/test/meal_planner_api_web/channels/planning_channel_test.exs` (extend)
- **Type**: test-first (red→green)
- **Description**: Spec scenario "Confirm reply and broadcast include cart fields" (web boundary half). Today's `confirm_proposal` tests only exercise the `PlanningChatService` fallback path (no `Generation.Server` registered in `Registry`) — this task adds the first test that `start_supervised!`s a `Generation.Server` under `MealPlannerApi.Generation.Generations` for the test account, seeds a pending proposal with cart-bearing slots, joins `planning:<account_id>`, pushes `"confirm_proposal"`, and asserts on `assert_reply/3` + `assert_broadcast/3`.
- **Acceptance criteria**:
  - [ ] test fails (RED) — before 4.2, reply/broadcast lack cart fields end-to-end
  - [ ] `assert_reply(ref, :ok, %{shopping_items_count: _, checkout_session_id: _, cart: _})`
  - [ ] `assert_broadcast("proposal_confirmed", %{shopping_items_count: _, checkout_session_id: _, cart: _})`
- **Estimated lines**: +55 / -0
- **Depends on**: 4.2

### Task 4.4 — GREEN: verification checkpoint (channel layer)

- **Files**: none expected; `meal_planner_api/lib/meal_planner_api_web/channels/planning_channel.ex` (only if 4.3 surfaces a real gap)
- **Type**: dedicated test (checkpoint)
- **Description**: The registered-server path in `handle_in("confirm_proposal", ...)` already forwards `Server.confirm/2`'s full reply map verbatim (`{:reply, {:ok, result}, socket}`) and relies on `do_confirm/2`'s own `broadcast/3` call — no channel code changes are expected. This task confirms that and documents it if true.
- **Acceptance criteria**:
  - [ ] Task 4.3 test GREEN with zero or near-zero diff to `planning_channel.ex`
- **Estimated lines**: +0 / -0
- **Depends on**: 4.3

**Phase 4 subtotal**: +100 / -5
**PR 2 subtotal (Phase 3+4)**: +373 / -17 (390 changed lines) — under budget as its own PR.

---

## Phase 5: Final Verification

### Task 5.1 — Full suite green + line-budget check

- **Files**: none (verification only)
- **Type**: dedicated test (checkpoint)
- **Description**: Run `mix test` for the full suite (not just scoped files) to catch regressions in `persist_scheduled_meals/2` callers, `PlanningChatService` fallback path, and any other `do_confirm/2` consumer. Then tally the actual `git diff --stat` net changed lines for the whole change (or per landed PR) against the 400-line budget and record the real number for `sdd-verify`.
- **Acceptance criteria**:
  - [ ] `mix test` passes with 0 failures across the whole suite
  - [ ] `mix precommit` (or project equivalent) is clean
  - [ ] actual `git diff --stat` net line count recorded per landed PR; flag to the user if either PR unexpectedly exceeds 400
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
