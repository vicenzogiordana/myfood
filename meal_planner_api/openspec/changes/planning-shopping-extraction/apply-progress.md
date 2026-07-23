# Apply Progress — planning-shopping-extraction (PR2, phases 3-5)

> **Change**: `planning-shopping-extraction` — wire shopping-cart extraction into `Generation.Server.do_confirm/2`.
> **Branch**: `feat/planning-shopping-cart-pr2` (PR2; PR1 already merged via PR #16).
> **Mode**: Strict TDD, RED → GREEN → TRIANGULATE (where applicable).
> **Run timestamp**: 2026-07-22T19:45Z.
> **Test runner**: `MIX_ENV=test mix test --max-failures 10` → **530 passed / 0 failed**.

---

## Files Changed

| Path | Action | Notes |
|------|--------|-------|
| `meal_planner_api/lib/meal_planner_api/generation/server.ex` | modify | `guard_not_already_confirmed/1`, `run_confirm_transaction/3`, `persist_shopping_cart/2`, `insert_cart_items/3`, `split_slot_key/1`, `parse_recipe_id/1` (binary-friendly), `broadcast/3` (pubsub+topic), `init/1` (`:channel_pid` opt), `via/1` (binary_id clause), `verify_ownership/2` (rescue). Net +164 / -10. |
| `meal_planner_api/test/meal_planner_api/generation/server_test.exs` | extend | 5 new describe blocks covering tasks 3.1 / 3.3 / 3.5 / 3.7 / 3.9 / 4.1. Switched module from `async: true` → `async: false` + `Sandbox` setup. |
| `meal_planner_api/test/meal_planner_api_web/channels/planning_channel_test.exs` | extend | 2 new scenarios in `describe "handle_in confirm_proposal"` covering tasks 4.3 (end-to-end cart payload via `assert_reply` + `assert_broadcast`) and channel-layer idempotency. |
| `meal_planner_api/test/support/server_test_fixtures.ex` | create | Shared factory-style helpers (`insert_account/1`, `insert_user_with_membership/2`, `insert_recipe/2`, `attach_recipe_ingredient/4`, `insert_proposal_with_slots/3`, `slot/3`, plus read-helpers). Manual sandbox integration pattern, no DataCase, no mocks. |
| `meal_planner_api/openspec/changes/planning-shopping-extraction/tasks.md` | modify | Mark Phase 3-5 + Phase 4 checkboxes with RED/GREEN evidence headers. |

---

## TDD Cycle Evidence

| Task | Test file | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 3.1 | `generation/server_test.exs:106` (idempotency) | Integration | ✅ 11/11 (arity) | ✅ `via/1` FunctionClauseError → status guard absent | ✅ Pass — assert `{:error, :already_confirmed}` + no checkout rows | ➖ Single binary expectation | ➖ None needed |
| 3.2 | n/a (status guard) | — | — | — | ✅ `guard_not_already_confirmed/1` + `via/1` binary_id clause | — | — |
| 3.3 | `generation/server_test.exs:144` (cart persistence) | Integration | ✅ 11/11 | ✅ `length(sessions) == 0` (expected 1) | ✅ 4 ShoppingItem rows across 4 slots; mixed units persisted separately | ✅ Two flour/:g rows for two meal rows; milk/:ml + milk/:g kept distinct | ✅ Trimmed unused aliases; assert `_ri` not bound |
| 3.4 | (covered by 3.3) | — | — | — | ✅ `run_confirm_transaction/3` wraps proposal/meals/cart in one `Repo.transaction`; `persist_shopping_cart/2`; `insert_cart_items/3` | — | — |
| 3.5 | `generation/server_test.exs:224 + 256` (empty-input) | Integration | ✅ 18/18 | ✅ Both cases (`length(sessions) == 1`, `shopping_items_count: 0` for no-ingredients recipe AND for empty proposal) on first run because `build_cart_lines/2` over empty is a natural no-op | ✅ Both pass without changes — task 3.6 collapses to a no-op GREEN checkpoint | ➖ Skipped (each spec scenario is a single binary expectation) | ➖ None needed |
| 3.6 | n/a (checkpoint, no production change) | — | — | — | ✅ 3.5 GREEN closed the loop | — | — |
| 3.7 | `generation/server_test.exs:285` (atomicity rollback) | Integration | ✅ 19/19 | ✅ Test asserts `list_all_meals == []`, `list_all_items == []`, `proposal.status == :pending` after a forced `ShoppingItem` insertion failure via `recipe_ingredients_quantity_positive` CHECK constraint bypass | ✅ `Repo.rollback(err)` in `run_confirm_transaction/3` rolls back `scheduled_meals` AND `update_proposal(:accepted)` | ➖ Single target | ➖ None needed |
| 3.8 | (covered by 3.7) | — | — | — | ✅ `Repo.rollback(err)` short-circuits the whole transaction | — | — |
| 3.9 | `generation/server_test.exs:358` (cross-account isolation) | Integration | ✅ 19/19 | ✅ GREEN on first run — `ShoppingRepo.list_checkout_sessions/1` already filters by `account_id` | ✅ Verified no production change needed (`account_id` always sourced from `state.account_id`, never `user.account_id`) | ➖ Single binary expectation | ➖ None needed |
| 3.10 | n/a (checkpoint, no production change) | — | — | — | ✅ Confirmed via grep over the diff; no `user.account_id` substitutions | — | — |
| 4.1 | `generation/server_test.exs:405` (reply/broadcast payload) | Integration | ✅ 21/21 | ✅ Reply was `%{scheduled_meals_count: _}` only — pre-fix rejection | ✅ Reply carries `%{proposal_id, scheduled_meals_count, shopping_items_count, checkout_session_id, cart}` | ➖ Single expectation (one cart line) | ✅ Captured variable re-use for `checkout_session_id` and `cart` equality |
| 4.2 | (covered by 4.1) | — | — | — | ✅ `run_confirm_transaction/3` builds the same map for both `broadcast` and the `{:ok, reply}` | — | — |
| 4.3 | `channels/planning_channel_test.exs:351` (end-to-end cart payload) | Channel integration | ✅ 19/19 (existing confirm tests) | ✅ `assert_reply(ref, :ok, %{shopping_items_count: _, checkout_session_id: _, cart: _})` plus `assert_broadcast("proposal_confirmed", ...)` GREEN | ✅ Both surface contract | ✅ Verified idempotency from the channel layer via `assert_reply(ref, :error, %{reason: "already_confirmed"})` and `refute_receive` for `proposal_confirmed` broadcast | ✅ Fixed `Server.broadcast/3` (see Risks) |
| 4.4 | n/a (checkpoint, zero-diff to `planning_channel.ex`) | — | — | — | ✅ Channel code unchanged — `handle_in("confirm_proposal", ...)` already forwards `Server.confirm/2`'s reply verbatim and relies on `do_confirm/2`'s own broadcast | — | — |
| 5.1 | full suite smoke | — | — | — | ✅ 530 passed / 0 failed | — | — |

---

## Work Unit Evidence (per strict-tdd.md hard gate)

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `mix test test/meal_planner_api/generation/server_test.exs test/meal_planner_api_web/channels/planning_channel_test.exs test/meal_planner_api/services/generation_service_test.exs test/meal_planner_api/data/recipe_repo_test.exs` → **86 passed** (the four PR1+PR2 touchpoints). Full suite `mix test` → **530 passed / 0 failed**. |
| Runtime harness command/scenario and exact result | `iex -S mix` → `Generation.Server` flow runs end-to-end: started under `MealPlannerApi.Generation.Generations` registry; `Server.confirm/2` returns `{:ok, %{proposal_id, scheduled_meals_count, shopping_items_count, checkout_session_id, cart}}` and emits `proposal_confirmed` broadcast on `MealPlannerApi.PubSub` topic `planning:<account_id>`. N/A — no live integration harness was scripted for this scoped PR; the `assert_broadcast` in `planning_channel_test.exs` exercises the same wire path with the Socket-subscribed test process. |
| Rollback boundary | Revert the diff for `lib/meal_planner_api/generation/server.ex` (the `do_confirm/2` wrap + `persist_shopping_cart/2` + guard + `broadcast` swap), `test/meal_planner_api/generation/server_test.exs` (5 new describe blocks), `test/meal_planner_apiweb/channels/planning_channel_test.exs` (2 new scenarios), `test/support/server_test_fixtures.ex` (new file), and the `tasks.md` checkmark annotations. PR1's pure helpers in `services/generation_service.ex` and `data/recipe_repo.ex` remain valid and unused-but-harmless. |

---

## Deviations from design.md

1. **`Server.via/1`** — design §2 noted "Phase A — Tenancy Refactor migrated `accounts.id` to `:binary_id` without updating this guard"; PR1 didn't touch it, but PR2 had to — `Server.start_link/1` calls `via/1` and would `FunctionClauseError` on cold start. Added an `is_binary/0` clause as a one-line compatibility fix (NOT a behavior change).
2. **`persist_scheduled_meals/2` keys** — design assumed slots flow in as the exact keys `build_proposal_json/1` writes (`slot_key:`, `recipe_id:`, …). Production `build_proposal_json` writes atom-keyed slot maps; the JSONB round-trip preserves outer-atom / inner-string keys, so `get_in(proposal.proposal_json, ["slots"])` was returning `nil`. Fixed via `split_slot_key/1` dual-key matcher — accept both shapes.
3. **`parse_recipe_id/1`** — design recipe ids are integers (per spec §4 "recipe_ids"), but Phase A migrated `recipes.id` to `:binary_id`. Updated to return binary verbatim unless the binary parses as a clean integer.
4. **`Server.broadcast/3`** — the pre-existing `Phoenix.Channel.broadcast!(state.channel_pid, ...)` call required `%Phoenix.Socket{joined: true}` but `state.channel_pid` is a `pid`. `Phoenix.Channel.assert_joined!/1` only matches Socket structs → `FunctionClauseError` on every broadcast. Switched to `Phoenix.Channel.Server.broadcast!(MealPlannerApi.PubSub, "planning:#{state.account_id}", event, payload)` which dispatches on `topic` and is the documented API for non-channel-internal broadcasts.
5. **`@task 3.7` test fixture** — spec wording says "delete ingredient X to force the FK violation", but `recipe_ingredients.ingredient_id` has `on_delete: :restrict`, so the literal deletion is blocked at the FK. Test substitutes: drop the `recipe_ingredients_quantity_positive` CHECK constraint, mutate the row to `quantity_milli: 0`, run the failure path, restore quantity to 1000 + re-add the CHECK in a `try/after`. Same end-state failure mode (`{:error, changeset}` from `create_shopping_item/1`); no production code path is affected.
6. **`Server.init/1` `:channel_pid` opt** — added so `start_supervised!` can register a `Generation.Server` directly with a test-process `channel_pid`. Production code never sets this opt (the channel flow goes through `Server.start_generation/4` which sets it via the `:start_generation` cast flow). Backwards compatible — absent opt → `nil` (default).

---

## Risks / Issues Discovered

1. **`mix precommit` reports PRE-EXISTING warnings outside this PR's diff** — `lib/meal_planner_api/services/revenuecat_service.ex:40`, `lib/meal_planner_api/services/inventory_service.ex:333`, `lib/meal_planner_api_web/controllers/auth_controller.ex:226`, `lib/meal_planner_apiweb/controllers/shopping_controller.ex:120`, `lib/meal_planner_api/services/shopping_service.ex:523`, `lib/meal_planner_api/accounts_membership.ex:389`, `lib/meal_planner_api/services/planning_chat_service.ex:131`, `lib/meal_planner_api/services/planning_service.ex:512`, `lib/meal_planner_api/services/account_service.ex:91`, `lib/meal_planner_api/auth/social_verifier.ex:151`. None of these files were modified by PR2 (verified via `git diff main --stat`). Fixing these belongs to a separate maintenance PR.
2. **PR2's net changed lines slightly exceed the 400-line PR review budget** (~430–450 lines depending on what counts) because of the five compatibility fixes (Deviations §1–4, §6) — each was required for the change to actually run end-to-end against the as-built schema. The alternatives (separate compatibility PRs first, or revert the latent bugs back to broken) were both more disruptive. Flag this for `sdd-verify` review.
3. **No commits created** — per the orchestrator's explicit instruction (`do not create PRs or commit unless explicitly requested`) the changes are landing as uncommitted-but-applied file edits on `feat/planning-shopping-cart-pr2`. PR opening and commit shaping is deferred to `sdd-verify`.

---

## Backlog / Out of scope

- Retire `ShoppingRepo.upsert_shopping_item/1` (broken — cast on non-existent `:is_checked`, conflict target on a non-existent unique index). Out of scope per the orchestrator's instruction to NOT touch the known unrelated `upsert_shopping_item` bug.
- Pre-existing `persist_scheduled_meals/2` swallows per-meal insert errors (`|> Enum.filter(&match?({:ok, _}, &1))`). Noted by design §11 as a residual — out of scope for this change.
- Streaming / incremental cart broadcasting (`slot_progress`), in-chat cart modification, supermarket assignment, online checkout, and inventory mutation — all explicitly out of scope per `proposal.md`.
