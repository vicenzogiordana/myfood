# Exploration: Meals Calendar and Atomic Menu Confirmation (#35)

> **Change**: `meals-calendar-atomic-confirmation`
> **GitHub issue**: #35 (parent #29, blocked by #30/#33/#34 — all merged to `main`).
> **OpenSpec preflight**: artifact store `openspec`, pace `interactive`, review budget 400 lines, delivery `ask-on-risk`.
> **Pre-existing active overlap**: `meal_planner_api/openspec/changes/planning-shopping-extraction/` — implemented on `feat/planning-shopping-cart-pr2`, merged to `main` via PR #18 (PR2, see `apply-progress.md`), **change folder not yet archived**.

---

## Current State

### Calendar surface (already in `main`)

- **Read — HTTP**: `GET /api/calendar` and `GET /api/calendar/slot` routed to `MealPlannerApiWeb.CalendarController` (`router.ex` lines 180–181) inside the `:enforce_capability` pipeline. Backed by `Persistence.Calendar.monthly_overview/5` and `get_slot_meal/4` (`persistence/calendar.ex`). Supports `start_date`, `end_date`, `selected_date`, `selected_slot`. `ScheduledMeal` schema (`persistence/planning/scheduled_meal.ex`) has `date :: :date`, `slot :: Ecto.Enum [:breakfast, :lunch, :snack, :dinner]`, `is_cooked`, `account_id`, `recipe_id`, `ai_generation_id`. Unique constraint `unique_index(:scheduled_meals, [:account_id, :date, :slot])` (migration `20260322092000`).
- **Read — Realtime**: `calendar:<account_id>` topic via `MealPlannerApiWeb.CalendarChannel` (`channels/calendar_channel.ex`). `join/3` checks membership, account match, `membership.status == :active`, then calls `ChannelCapability.authorize(membership)`. Handles `toggle_favorite`, `upsert_meal`, `delete_meal`, `set_is_cooked`.
- **Mutations**: `Calendar.upsert_scheduled_meal/2` is per-`(date, slot)` upsert; no range-replacement API exists yet.

### Account expiration (already in `main`)

- `MealPlannerApi.AccountAccess.eligible?/1` (`account_access.ex`) — pure over preloaded `Account`. Half-open intervals: trial `[trial_started_at, trial_ends_at)` and entitlement `is_active == true AND (expiration_date > now OR grace_period_expires_date > now)`. Returns `false` for missing/nil.
- HTTP gate: `MealPlannerApiWeb.Plugs.EnforceCapability` reads `Application.get_env(:meal_planner_api, :revenuecat_access_enforcement, false)` and rejects with `403 {"error":"subscription_required"}`. **The flag is off by default** per `design.md` "Migration/Rollout"; both transports share the same flag via `ChannelCapability.enforcement_enabled?/0`.
- Channel gate: `ChannelCapability.authorize(%AccountMembership{})` mirrors the HTTP plug.
- Belt-and-braces: `PlanningChannel.handle_in("start_planning", ...)` re-checks `AccountAccess.eligible?(account_id)` at handler time (line 370), and the `ai-intent-boundary` flows re-validate via `:check_account_eligible_fn`.

### Lock pattern (already in `main`)

- `Persistence.Planning.PlanningSession` schema (`persistence/planning/planning_session.ex`):
  - `:date` columns `range_from`, `range_to`.
  - Status `Ecto.Enum` `[:active, :cancelled, :expired, :lost_lock, :committed]`.
  - `lock_owner_user_id`, `lock_owner_membership_id`, `lease_expires_at` (120 s).
  - Partial `EXCLUDE USING gist (account_id WITH =, daterange(range_from, range_to, '[]') WITH &&) WHERE (status = 'active')` (migration `20260902190000`).
- `Data.PlanningRepo.create_session/2` rescues `Ecto.ConstraintError type: :exclusion` → `{:error, :overlapping_range}`.
- `Generation.PlanningSessionServer` (`generation/planning_session_server.ex`): `Process.monitor`s the owner channel pid; on **abnormal** exit transitions the row to `:lost_lock` and broadcasts `session_lost_lock` on `planning:<account_id>`. Clean exit (`:normal`, `:shutdown`) leaves the session alive. `:transient` restart strategy rehydrates from the DB row on crash.
- `authorize_actor/3` rejects non-owner / non-account-owner actors with `{:error, :forbidden}`. Cancel/expire/lost-lock/commit all wrap the row update + child hard-delete in `Repo.transaction/1`.

### Confirm flow (mixed: channel atomic, HTTP not)

- **Channel path (atomic)**: `PlanningChannel.handle_in("confirm_proposal", ...)` looks up `MealPlannerApi.Generation.Generations` Registry; if a `Generation.Server` exists, calls `Server.confirm(pid, proposal_id)` → `Generation.Server.do_confirm/2` (`generation/server.ex` lines 286–334) → `run_confirm_transaction/3` wraps `PlanningRepo.update_proposal(:accepted)` + `persist_scheduled_meals/2` + `persist_shopping_cart/2` inside one `Repo.transaction/1` with `Repo.rollback(err)`. Idempotency via `guard_not_already_confirmed/1` returns `{:error, :already_confirmed}`. Landed by PR #18 (`planning-shopping-extraction` PR2) — `apply-progress.md` records 530/530 tests passing.
- **HTTP path (NOT atomic, legacy)**: `POST /api/planning/proposals/:proposal_id/confirm` → `PlanningChatController.confirm/2` → `PlanningChatService.confirm_proposal/2` (lines 103–165). This path updates `:accepted` first, then `Enum.flat_map` over `PlanningRepo.schedule_meal/1` with no transaction and **silently swallows per-meal errors** (`{:error, _} -> []`). No shopping-cart write. Same path is used as fallback when no `Generation.Server` is registered.
- **Gap vs planning-sessions spec**: `spec.md` requirement "Confirm writes cart and commits" requires `do_confirm/2` to also call `PlanningRepo.mark_committed/3` so the session row transitions to `:committed`. Currently `do_confirm/2` does NOT call `mark_committed/3` — the row stays `:active`. Spec/code drift.

---

## Overlap with planning-shopping-extraction

| #35 AC | Already covered? | Notes |
|---|---|---|
| AC #1 — expired Account cannot read calendar / confirm menu | **YES** (transports gated by `:enforce_capability` + `ChannelCapability`) | Flag `:revenuecat_access_enforcement` is the single switch; off by default. #35 must call this out, NOT redefine. |
| AC #2 — invalid / lost / foreign lock rejected | **Partial** — `PlanningSession` has the primitives (`:lost_lock` enum, `authorize_actor`, EXCLUDE, sweeper) but `do_confirm/2` does NOT route through them. | #35 needs to add a lock reference (session_id / lock_token) to the confirm payload and wire `mark_committed/3` into `do_confirm/2`. |
| AC #3 — replacement preserves dates outside selected range | **NO** — no range-replacement API exists. | #35 adds `Persistence.Calendar.replace_scheduled_meals_for_range/3`. |
| AC #4 — menu + derived effects commit together or not at all | **YES** (channel path via `run_confirm_transaction/3`, PR #18) | #35 should reference the planning-shopping-extraction scenario verbatim, not duplicate. Spec section should explicitly cite `specs/planning-shopping-cart.md` §"Cart persistence and scheduled-meal persistence are atomic". |

**Coordination rule for #35**: the spec and proposal should explicitly cross-reference `specs/planning-shopping-cart.md` for AC #4 and the upcoming `specs/calendar.md` for AC #1 / AC #3. The implementation must NOT re-wrap the existing `Repo.transaction` in a second `Ecto.Multi` — that risks double-rollback semantics.

---

## Affected Areas

### Already-shipped (read-only references)

- `meal_planner_api/lib/meal_planner_api/persistence/calendar.ex` — read model for AC #1 and AC #3 surface.
- `meal_planner_api/lib/meal_planner_api/persistence/planning/scheduled_meal.ex` — schema with the `(account_id, date, slot)` unique key (used by AC #3).
- `meal_planner_api/lib/meal_planner_api/persistence/planning/planning_session.ex` — lock primitives for AC #2.
- `meal_planner_api/lib/meal_planner_api/account_access.ex` — `eligible?/1` source for AC #1.
- `meal_planner_api/lib/meal_planner_api_web/plugs/enforce_capability.ex` — HTTP gate for AC #1.
- `meal_planner_api/lib/meal_planner_api_web/channel_capability.ex` — channel gate for AC #1.
- `meal_planner_api/lib/meal_planner_api_web/channels/{calendar,planning}_channel.ex` — transport layer for AC #1 and AC #2.
- `meal_planner_api/lib/meal_planner_api/generation/server.ex` — already implements AC #4 transactionally (PR #18); needs AC #2 wiring.
- `meal_planner_api/openspec/specs/planning-sessions/spec.md` — already defines AC #2 lock lifecycle (the spec drifts from implementation for the confirm path).
- `meal_planner_api/openspec/changes/planning-shopping-extraction/specs/planning-shopping-cart.md` — already covers AC #4 with 9 scenarios.
- `meal_planner_api/openspec/specs/accounts/spec.md`, `auth/spec.md`, `channels/spec.md` — provide context.

### Net-new / net-modified (owned by #35)

- `meal_planner_api/lib/meal_planner_api/persistence/calendar.ex` — add `replace_scheduled_meals_for_range/3` (delete-by-range + insert in one `Ecto.Multi`).
- `meal_planner_api/lib/meal_planner_api/data/planning_repo.ex` — add `replace_scheduled_meals_for_range/4` query helper; possibly wire `mark_committed/3` into the confirm pipeline (AC #2).
- `meal_planner_api/lib/meal_planner_api/services/planning_chat_service.ex` — either retire `confirm_proposal/2` or make it call `Generation.Server.do_confirm/2` so HTTP and channel share the atomic path (close the dual-path gap surfaced above).
- `meal_planner_api/lib/meal_planner_api/generation/server.ex` — accept an optional `session_id` / lock token; reject if session is missing, `:lost_lock`, or owned by another membership (AC #2); call `PlanningRepo.mark_committed/3` after `run_confirm_transaction/3` succeeds.
- `meal_planner_api/lib/meal_planner_api_web/controllers/calendar_controller.ex` — new action for range replacement (e.g. `PUT /api/calendar/meals/range`), plus serialization updates if `replace` returns a per-meal summary.
- `meal_planner_api/lib/meal_planner_api_web/router.ex` — register the new route under `:enforce_capability`.
- `meal_planner_api/openspec/specs/calendar.md` (NEW) — define the calendar capability contract covering AC #1, AC #2, AC #3.
- Tests: `meal_planner_api/test/meal_planner_api/persistence/calendar_test.exs` (NEW), extend `meal_planner_api/test/meal_planner_api_web/controllers/calendar_controller_test.exs`, extend `meal_planner_api/test/meal_planner_api/generation/server_test.exs` for the new lock-rejection scenarios and the `mark_committed` wire-up.
- Migration: **only if** AC #3 demands a new index (e.g. `(account_id, date)` partial index to speed up the range-delete query). Probably not needed — the existing `(account_id, date, slot)` unique covers it.

### Files explicitly OUT of scope for #35

- `meal_planner_api/lib/meal_planner_api/data/recipe_repo.ex`, `shopping_repo.ex`, `services/generation_service.ex` (already touched by planning-shopping-extraction PR1/PR2 — no further changes needed).
- `meal_planner_api/lib/meal_planner_api/integrations/python_client.ex` — orphan mentioned in planning-shopping-extraction proposal §"Out of Scope #3".

---

## Approaches

### Approach A — Reuse `PlanningSession` lock, add range-replacement API, retire HTTP confirm path

**Description**: Adopt `PlanningSession` lock as the single source of truth for AC #2. The confirm path requires a `session_id`; `do_confirm/2` calls `PlanningRepo.mark_committed/3` after the existing `run_confirm_transaction/3`. Add `Persistence.Calendar.replace_scheduled_meals_for_range/3` for AC #3 (delete by `(account_id, date in [from, to])` + insert in one `Ecto.Multi`). Retire `PlanningChatService.confirm_proposal/2` — the HTTP and channel paths both go through `Generation.Server.do_confirm/2`. The spec reuses `planning-shopping-cart.md` for AC #4 and explicitly cross-references the existing `:enforce_capability` plug for AC #1.

- **Pros**: Honours existing infrastructure (no new lock table, no new schema, no new migration). Closes the spec/code drift on `mark_committed`. Forces alignment of HTTP and channel confirm paths (one atomic code path). Spec stays small (mostly references).
- **Cons**: Touches 2 transport paths (channel + HTTP) and `Generation.Server.do_confirm/2` — risk of regressing the 530-test PR2 suite. Requires the frontend to pass a `session_id` on confirm; the mobile team will need an update.
- **Effort**: Medium

### Approach B — Add a new column-level lock on `scheduled_meals`, leave the dual confirm paths

**Description**: Add `lock_token :: binary_id` and `lock_owner_membership_id` columns to `scheduled_meals`. A `POST /api/calendar/lock` endpoint grants the lock to a `(account_id, range)` tuple; `do_confirm/2` checks it. Range-replacement via the same API. Leave `PlanningChatService.confirm_proposal/2` running (dual path).

- **Pros**: AC #2 is satisfied by a column the meals themselves own, which feels more direct. Frontend can lock and confirm in one round trip without first opening a `PlanningSession`.
- **Cons**: **New lock primitive that duplicates `PlanningSession`.** Violates the "deep modules, not shallow helpers" principle. The migration and the new lock endpoints exceed the 400-line review budget. Two confirm paths remain (the legacy HTTP one stays non-atomic) — defeats AC #4 by omission. Couples `scheduled_meals` lifecycle to a column that has nothing to do with calendar generation.
- **Effort**: High

### Approach C — Minimal: only add range-replacement, defer lock to a follow-up

**Description**: Only implement AC #3 (range-replacement API + route). Skip AC #2 entirely and let it ride on `PlanningSession` via a later change.

- **Pros**: Smallest slice. Stays well under the 400-line budget. Can land quickly.
- **Cons**: Doesn't satisfy the issue's full AC list. "Invalid / lost / foreign lock is rejected" stays as a future ticket, and `do_confirm/2` still doesn't call `mark_committed/3` — the planning-sessions spec/code drift remains.
- **Effort**: Low

---

## Recommendation

**Approach A**. The lock primitives already exist; duplicating them on `scheduled_meals` (Approach B) is a layering violation and would force a migration, a new endpoint, and a second lock protocol — none of which the codebase needs. Approach C leaves the spec/code drift intact and ships a half-AC issue.

Approach A coordinates cleanly with `planning-shopping-extraction`: AC #4 is **already** delivered by PR #18, so the #35 spec must explicitly say "Cart persistence and scheduled-meal persistence are atomic — see `planning-shopping-cart.md` §…". AC #1 is **already** delivered by `:enforce_capability` + `ChannelCapability`; the spec should add one explicit scenario for "expired Account joins `calendar:<id>` → `subscription_required`" rather than redefining the gate.

The migration risk is minimal — no new tables, no new columns (unless AC #3 wants a partial index, optional). The code risk is concentrated in `do_confirm/2` and `PlanningChatService.confirm_proposal/2`; both are well-covered by the existing 530-test PR2 suite, so an `sdd-verify` step will catch regressions.

**Phasing inside #35** (assuming `ask-on-risk` delivery):

1. **PR1 (AC #3 only)** — `replace_scheduled_meals_for_range/3` + route + controller + persistence tests. ≤ 200 lines.
2. **PR2 (AC #1 scenario + AC #2 wire-up)** — spec scenarios; `do_confirm/2` accepts `session_id`, calls `mark_committed/3`; tests for `:lost_lock` / foreign / missing / already-committed rejections. ≤ 250 lines.
3. **PR3 (retire HTTP non-atomic path)** — `PlanningChatService.confirm_proposal/2` either deleted or made a thin shim over `Server.confirm/2`. ≤ 100 lines.

PR1 + PR2 fit the 400-line budget individually; PR3 is housekeeping.

---

## Risks

- **Flag off by default**: `:revenuecat_access_enforcement` is off per `revenuecat-access-enforcement` design. When off, AC #1 is **not** enforced at runtime. #35 must either (a) add an explicit test that flips the flag, or (b) raise the rollout posture with the maintainer. If neither happens, the AC is satisfied by code review but not by production traffic — a soft failure mode.
- **Spec/code drift on `mark_committed`**: `planning-sessions/spec.md` already requires the confirm path to transition the session row to `:committed`. `do_confirm/2` does not yet do this. Wiring it in is mandatory for AC #2 but **must be sequenced after** the PR #18 test suite is confirmed stable on `main`. If `main` has moved on, the test fixtures may need updating.
- **Dual confirm paths today**: the HTTP `POST /api/planning/proposals/:proposal_id/confirm` still hits `PlanningChatService.confirm_proposal/2`, which is non-atomic. AC #4 is satisfied on the channel path only. If the mobile client still calls the HTTP path, AC #4 is silently broken. PR3 must retire or shim the legacy path; otherwise the change is half-delivered.
- **Range replacement on a partial-EXCLUDE-guarded session**: if `do_confirm/2` is wired through `mark_committed/3`, the session must be in `:active`. A replacement that succeeds after a session has gone `:lost_lock` is a contradiction. AC #2's "lost lock" rejection must be tested end-to-end, not just at the `PlanningRepo` layer.
- **Calendar session lifecycle gap**: the calendar doesn't currently own a `PlanningSession`. The `CalendarChannel` operates on `scheduled_meals` directly. For AC #2 to make sense for calendar reads + confirm, the change must decide whether a calendar-driven confirm requires opening a `PlanningSession` first, or whether the confirm wire-up is sufficient on its own. The orchestrator should be told this is an open question.

---

## Ready for Proposal

**Yes** — with three conditions:

1. The orchestrator should tell the user that AC #1 and AC #4 are **already in `main`** (not "not yet implemented"). The #35 proposal should be explicit about reusing both.
2. The user must choose whether to retire `PlanningChatService.confirm_proposal/2` (PR3) or leave the HTTP path as a separate, slower-to-deprecate surface. This is a delivery-strategy question, not a technical one.
3. The user must confirm the rollout posture for `:revenuecat_access_enforcement` before the spec is drafted — if the flag stays off by default, AC #1 is a code-review AC, not a runtime AC, and the spec must say so.

The orchestrator should NOT launch `sdd-propose` until the user has answered the third question (flag posture). The first two are documented as recommendations in the proposal itself.
