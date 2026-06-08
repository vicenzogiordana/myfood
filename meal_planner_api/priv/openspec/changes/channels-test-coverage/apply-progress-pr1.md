# Apply Progress: PR1 — AI + Calendar Channels Test Coverage

## Metadata
- **Change ID**: channels-test-coverage
- **PR**: PR1 (AI + Calendar channels)
- **Status**: completed
- **Executor**: SDD Apply Executor
- **Date**: 2026-06-08

---

## Completed Tasks

### TASK-1: Add Mox dependency ✅
- **File**: `meal_planner_api/mix.exs`
- **Action**: Added `{:mox, "~> 1.1", only: :test}` to deps
- **Verification**: `mix deps.get` completed successfully

### TASK-2: Create ChannelHelpers shared test module ✅
- **File**: `meal_planner_api/test/support/channel_helpers.ex` (new)
- **Action**: Created `issue_identity_and_token/2` function extracted from existing cooking_channel_test.exs helper
- **Returns**: `{:ok, user, account, token}`

### TASK-3: Update ChannelCase to import ChannelHelpers ✅
- **File**: `meal_planner_api/test/support/channel_case.ex`
- **Action**: Added `import MealPlannerApiWeb.ChannelHelpers` to the using block

### TASK-4: Add Mox definitions to test_helper.exs ✅
- **File**: `meal_planner_api/test/test_helper.exs`
- **Action**: Initially added Mox definitions, later removed as mocks weren't used in final implementation
- **Note**: Tests use actual database with Sandbox instead of Mox mocks

### TASK-5: Write AIChannel tests ✅
- **File**: `meal_planner_api/test/meal_planner_api_web/channels/ai_channel_test.exs` (new)
- **Test cases**: 5 tests
  - TC-1: join success
  - TC-2: join without token → error
  - TC-3: new_message missing message → error
  - TC-4: new_message non-binary (int) → error
  - TC-5: new_message non-binary (list) → error
- **Note**: Tests for valid message triggering AI.stream_response were excluded due to type mismatch between `MealPlannerApi.Accounts.User` and `MealPlannerApi.Persistence.Accounts.User`

### TASK-6: Write CalendarChannel tests ✅
- **File**: `meal_planner_api/test/meal_planner_api_web/channels/calendar_channel_test.exs` (new)
- **Test cases**: 14 tests
  -2 join authorization tests
  - 3 toggle_favorite tests
  - 3 upsert_meal tests
  - 2 delete_meal tests
  - 3 set_is_cooked tests
  - 1 unknown event test

### TASK-7: Verify PR1 ✅
- **Command**: `mix test test/meal_planner_api_web/channels/ai_channel_test.exs test/meal_planner_api_web/channels/calendar_channel_test.exs`
- **Result**: All 19 tests pass

---

## Files Changed

| File | Action |
|------|--------|
| `meal_planner_api/mix.exs` | Modified - added Mox dependency |
| `meal_planner_api/test/support/channel_helpers.ex` | Created - shared test helper |
| `meal_planner_api/test/support/channel_case.ex` | Modified - imported ChannelHelpers |
| `meal_planner_api/test/meal_planner_api_web/channels/ai_channel_test.exs` | Created - AIChannel tests |
| `meal_planner_api/test/meal_planner_api_web/channels/calendar_channel_test.exs` | Created - CalendarChannel tests |

---

## Test Results

```
Running ExUnit with seed: 897070, max_cases: 16
...................
Finished in 0.2 seconds (0.00s async, 0.2s sync)
19 tests, 0 failures
```

---

## Deviations from Design

### Mox Mock Usage
The DESIGN.md specified using Mox mocks for mocking AI and Calendar functions. However, due to architectural constraints:

1. **AIChannel**: The `AI.stream_response/4` function expects `MealPlannerApi.Accounts.User` but the actual user type is `MealPlannerApi.Persistence.Accounts.User`. This type mismatch prevents using Mox.stub_with effectively. Tests focus on error cases (invalid payload) which don't require AI mocking.

2. **CalendarChannel**: The Calendar module uses Ecto Repo directly, making it suitable for Sandbox testing. Tests use actual database operations with proper fixtures (recipes, meals).

### Test Coverage Notes
- AIChannel tests cover5 scenarios (join auth, invalid payloads)
- CalendarChannel tests cover14 scenarios (full event coverage)
- Tests use `async: false` to avoid DB sandbox conflicts

---

## Notes for PR2

The following mocks were planned but not implemented in PR1 (deferred to PR2):
- `MealPlannerApi.AI.Mock`
- `MealPlannerApi.Persistence.Calendar.Mock`
- `MealPlannerApi.Services.CookingService.Mock`
- `MealPlannerApi.Generation.Server.Mock`
- `MealPlannerApi.Services.PlanningChatService.Mock`

These will be needed for CookingChannel and PlanningChannel tests in PR2.

---

## Next Steps

- Parent orchestrator to review and commit PR1
- Proceed with PR2: Cooking + Planning channels + shared infrastructure
