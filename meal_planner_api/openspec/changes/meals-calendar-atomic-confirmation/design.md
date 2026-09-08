# Design: Meals Calendar and Atomic Confirmation

## Technical Approach

Approach A ships three stacked-to-main PRs: transactional calendar range replacement (PR1), PlanningSession-locked channel confirmation (PR2), and legacy HTTP confirmation removal (PR3). It implements `specs/calendar/spec.md` and the planning-sessions delta while reusing the existing PlanningSession lock, the single channel `Repo.transaction/1` required by `planning-shopping-cart.md`, and the existing `:enforce_capability`/`ChannelCapability.authorize/1` gates.

## Architecture Decisions

| Decision / Choice | Alternatives considered | Rationale |
|---|---|---|
| Reuse `PlanningSession` as the confirmation lock. | Lock columns on `scheduled_meals`; no lock. | It already owns account/range exclusivity, membership ownership, lease, and terminal states; another primitive would duplicate policy. |
| Convert `run_confirm_transaction/3` to one `Ecto.Multi`, validating and row-locking the session first, then appending proposal, meals, cart, and `:committed` steps. | Commit separately; nested transaction. | One outer `Repo.transaction/1` preserves the shipped meal/cart rollback contract and prevents session-status drift or TOCTOU confirmation. |
| Put inclusive, account-scoped delete-by-range plus normalized `insert_all` behind `Persistence.Calendar.replace_scheduled_meals_for_range/3`; `Data.PlanningRepo` owns query construction. | Controller loop; per-row upserts. | This is a deep persistence interface: callers cannot omit scope or atomicity, and the existing `(account_id,date,slot)` index remains authoritative. |
| Reuse `:enforce_capability` and `ChannelCapability.authorize/1`; add flag-enabled route/channel proof only. | New plug; handler-local entitlement checks. | Both transports already share `AccountAccess`; duplicate gates would drift. Calendar account scope continues to come from `current_membership.account_id` because this route has no account path parameter. |
| Remove the HTTP confirm route/action, service function, and channel fallback. | Deprecate only; repair HTTP separately; bridge. | Search found no `assets` caller: only the router/controller, channel fallback, and their tests consume it. Removal leaves one atomic confirmation path. |

## Data Flow

```text
PR1  PUT /api/calendar/meals/range → auth → current_membership account scope
     → :enforce_capability → CalendarController.replace_range/2
     → Persistence.Calendar.replace_scheduled_meals_for_range/3
     → Ecto.Multi(delete inclusive account range, insert_all) → Repo.transaction/1 → response

PR2  planning:<account_id> confirm_proposal(proposal_id, session_id)
     → Generation.Server.do_confirm/3 → PlanningSession ownership/status/lease row lock
     → run_confirm_transaction/3 Multi(proposal, meals, cart, mark_committed)
     → Repo.transaction/1 → :committed → reply + proposal_confirmed broadcast

PR3  remove PlanningChatService.confirm_proposal/2
     → remove POST proposal-confirm route/controller and channel fallback
     (consumer search: no assets caller; legacy lib/test references only)
```

## File Changes

| File | Action | Description |
|---|---|---|
| `lib/meal_planner_api/persistence/calendar.ex` | Modify | Add the range-replacement interface and result mapping. |
| `lib/meal_planner_api/data/planning_repo.ex` | Modify | Add scoped range query/Multi helpers; extend `mark_committed/2` to composable `/3`. |
| `lib/meal_planner_api_web/controllers/calendar_controller.ex` | Modify | Parse/validate range payload and serialize replacement result. |
| `lib/meal_planner_api_web/router.ex` | Modify | Add PUT range route; remove legacy proposal-confirm route. |
| `test/meal_planner_api/persistence/calendar_test.exs` | Create | Atomic, duplicate, range, and tenant tests. |
| `test/meal_planner_api_web/controllers/calendar_controller_test.exs` | Modify | Route, scope, validation, and flag-enabled denial tests. |
| `lib/meal_planner_api/generation/server.ex` | Modify | Require `session_id`; validate lock; extend confirmation Multi. |
| `lib/meal_planner_api_web/channels/planning_channel.ex` | Modify | Require/forward session; remove non-atomic fallback. |
| `test/meal_planner_api/{data/planning_repo_test.exs,generation/server_test.exs}` | Modify | Multi contract, lock errors, commit/rollback tests. |
| `test/meal_planner_api_web/channels/planning_channel_test.exs` | Modify | Payload, foreign/lost lock, entitlement, reply/broadcast tests. |
| `lib/meal_planner_api/services/planning_chat_service.ex` | Modify | Delete `confirm_proposal/2` only. |
| `lib/meal_planner_api_web/controllers/planning_chat_controller.ex` | Modify | Delete `confirm/2` and serializer. |
| `test/meal_planner_api_web/controllers/planning_chat_controller_test.exs` | Modify | Remove retired HTTP confirmation coverage. |

## Interfaces / Contracts

```elixir
Calendar.replace_scheduled_meals_for_range(account_id, {from, to}, new_meals) ::
  {:ok, %{replaced: non_neg_integer()}} | {:error, atom()}

Generation.Server.do_confirm(account_id, proposal_id, session_id) ::
  {:ok, term()} |
  {:error, :foreign_lock | :lost_lock | :terminal_lock | :missing_lock | atom()}

PlanningRepo.mark_committed(account_id, session_id, multi \\ Ecto.Multi.new()) :: Ecto.Multi.t()
```

Missing rows map to `:missing_lock`; account/membership mismatch to `:foreign_lock`; `:lost_lock` or an elapsed active lease to `:lost_lock`; `:cancelled | :expired | :committed` to `:terminal_lock`. Replacement rejects reversed ranges, out-of-range/cross-account meals, and duplicate date/slot input before writes.

## Testing Strategy

| Layer | What to Test | Approach |
|---|---|---|
| Unit | Range/payload normalization and lock-error mapping. | Focused pure-function tests. |
| Integration | Outside-date preservation, duplicate/cross-account rejection, rollback after insert/cart failure, successful atomic commit, foreign/lost/terminal/missing locks, and flag-enabled expired Account read/confirm denial. | Ecto Sandbox; channel processes via `start_supervised!/1`; lifecycle synchronization via `Process.monitor/1` and `assert_receive {:DOWN, ...}`; run focused `mix test` files then `mix precommit`. |
| E2E | N/A. | No E2E harness exists; controller/channel integration tests cover transport boundaries. |

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary. The Phoenix HTTP route does not invoke OS commands or automation.

## Migration / Rollout

No DB migration is required; the existing unique index is reused. `:revenuecat_access_enforcement` remains off by default, with PR2 adding flag-enabled runtime proof for AC #1. Each budgeted PR merges independently to `main`; no per-PR feature flag is needed.

## Open Questions

None. `PlanningRepo.mark_committed/2` exists and will become composable `/3`; consumer search found no asset caller requiring a bridge.
