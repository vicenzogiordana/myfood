# Tasks: Meals Calendar and Atomic Confirmation

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated lines | ~550 (PR1≤200; PR2≤250; PR3≤100) |
| 400-line budget risk | Low |
| Chained PRs | Yes |
| Suggested split | PR1→PR2→PR3 |
| Strategy | ask-on-risk |
| Chain | stacked-to-main |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|---|---|---|---|---|---|
| 1 | Ranges | PR1 (3 commits) | `mix test test/meal_planner_api/persistence/calendar_test.exs test/meal_planner_api_web/controllers/calendar_controller_test.exs --working-directory meal_planner_api` | N/A—no E2E | Revert PR1 (no DB migration) |
| 2 | Confirmation | PR2 (3 commits) | `mix test test/meal_planner_api/generation/server_test.exs test/meal_planner_api_web/channels/planning_channel_test.exs --working-directory meal_planner_api` (`:revenuecat_access_enforcement` on in entitlement test) | N/A—no E2E | Revert PR2 (no DB migration) |
| 3 | HTTP retirement | PR3 (2 commits) | `mix precommit --working-directory meal_planner_api` | N/A—no E2E | Revert PR3 (restores HTTP route/service function for emergency consumer rollback) |

## Phase 1: PR1 — Calendar

- [x] 1.1.1 RED: add `test/meal_planner_api/persistence/calendar_test.exs` duplicate/cross-account cases (Scenario: Reject duplicate slot; Cross-account replacement rejected).
- [x] 1.1.2 GREEN: add scoped delete/insert Multi helpers in `lib/meal_planner_api/data/planning_repo.ex`.
- [x] 1.1.3 REFACTOR: simplify range helpers in `lib/meal_planner_api/data/planning_repo.ex`.
- [x] 1.2.1 RED: test preservation/rollback in `test/meal_planner_api/persistence/calendar_test.exs` (Scenario: Replace inside range; Preserve partially adjacent slot; Failed replacement rollback).
- [x] 1.2.2 GREEN: implement transactional `replace_scheduled_meals_for_range/3` in `lib/meal_planner_api/persistence/calendar.ex`.
- [x] 1.2.3 REFACTOR: normalize result/errors in `lib/meal_planner_api/persistence/calendar.ex`.
- [x] 1.3.1 RED: test expired denial/tenant scope in `test/meal_planner_api_web/controllers/calendar_controller_test.exs` (Scenario: Expired replacement denied; Account reads only its meals).
- [x] 1.3.2 GREEN: wire PUT and validate scoped payloads in `lib/meal_planner_api/{router.ex,controllers/calendar_controller.ex}`.
- [x] 1.3.3 REFACTOR: deduplicate validation in `lib/meal_planner_api_web/controllers/calendar_controller.ex`.
- [x] 1.4 Run `mix precommit --working-directory meal_planner_api` for `meal_planner_api/mix.exs` (read-only) — 785/786 pass, 1 pre-existing optimizer test failure unrelated to PR1.

## Phase 2: PR2 — Confirmation

- [ ] 2.1.1 RED: test rollback-safe composable `mark_committed/3` Multi in `test/meal_planner_api/data/planning_repo_test.exs` (Scenario: Failed confirmation preserves).
- [ ] 2.1.2 GREEN: append `mark_committed/3` to supplied Multi in `lib/meal_planner_api/data/planning_repo.ex`.
- [ ] 2.1.3 REFACTOR: clarify Multi steps in `lib/meal_planner_api/data/planning_repo.ex`.
- [ ] 2.2.1 RED: test commit/rollback and missing/lost/terminal cases in `test/meal_planner_api/generation/server_test.exs` (Scenario: Successful commits; Failed preserves; Missing/lost/terminal lock).
- [ ] 2.2.2 GREEN: require/row-lock `session_id` and append commit in `lib/meal_planner_api/generation/server.ex`.
- [ ] 2.2.3 REFACTOR: consolidate lock errors in `lib/meal_planner_api/generation/server.ex`.
- [ ] 2.3.1 RED: test foreign lock/flag-enabled expiry in `test/meal_planner_api_web/channels/planning_channel_test.exs` (Scenario: Foreign lock rejected; Expired Account read denied).
- [ ] 2.3.2 GREEN: forward `session_id` and capability replies in `lib/meal_planner_api_web/channels/planning_channel.ex`.
- [ ] 2.3.3 REFACTOR: deduplicate payload guards in `lib/meal_planner_api_web/channels/planning_channel.ex`.
- [ ] 2.4 Run `mix precommit --working-directory meal_planner_api` for `meal_planner_api/mix.exs` (read-only).

## Phase 3: PR3 — HTTP Retirement

- [ ] 3.1 Search `meal_planner_api/{assets,lib,test}` (read-only) for `confirm_proposal`; record no asset caller.
- [ ] 3.2.1 RED: update `test/meal_planner_api_web/{controllers/planning_chat_controller_test.exs,channels/planning_channel_test.exs}` for absent HTTP and atomic channel success (Scenario: Confirm writes cart and commits).
- [ ] 3.2.2 GREEN: delete HTTP service/action/route and fallback in `lib/meal_planner_api/{services/planning_chat_service.ex,web/controllers/planning_chat_controller.ex,web/router.ex,web/channels/planning_channel.ex}`.
- [ ] 3.2.3 REFACTOR: remove stale HTTP helpers in `test/meal_planner_api_web/controllers/planning_chat_controller_test.exs`.
- [ ] 3.3 Run `mix precommit --working-directory meal_planner_api` for `meal_planner_api/mix.exs` (read-only).
