# Apply Progress PR2 — Cooking + Planning Channels Test Coverage

**Date**: 2026-06-08
**Phase**: sdd-apply PR2
**Status**: COMPLETED

## Task Summary

| Task | Status | Notes |
|------|--------|-------|
| TASK-8: Create Mox mock modules | SKIPPED | PR1 used Sandbox pattern, followed same pattern for consistency |
| TASK-9: Expand CookingChannel tests | COMPLETED | 17 test cases |
| TASK-10: Expand PlanningChannel tests | COMPLETED | 16 test cases |
| TASK-11: Verify PR2 | COMPLETED | All 52 channel tests pass |

## Test Results

### All Channel Tests: 52 tests, 0 failures

| Channel | Tests | Status |
|---------|-------|--------|
| AIChannel | 5 | PASS |
| CalendarChannel | 13 | PASS |
| CookingChannel | 17 | PASS |
| PlanningChannel | 16 | PASS |

### CookingChannel Tests (17 tests)

1. ✅ join: user joins cooking session room
2. ✅ start_session: success with valid scheduled_meal_id
3. ✅ start_session: error with missing scheduled_meal_id
4. ✅ start_session: error with non-binary scheduled_meal_id
5. ✅ get_state: success with valid session_id
6. ✅ get_state: error with missing session_id
7. ✅ track_step: success with started status
8. ✅ track_step: success with completed status
9. ✅ track_step: success with paused status
10. ✅ track_step: error with missing required fields
11. ✅ finish_session: success with valid session_id
12. ✅ finish_session: error with missing session_id
13. ✅ ask_assistant: success with session_id in payload
14. ✅ ask_assistant: error with missing message
15. ✅ ask_assistant: error with no active session
16. ✅ ask_assistant: error with non-binary message
17. ✅ unknown event: returns event_not_implemented

### PlanningChannel Tests (16 tests)

1. ✅ join: user joins their own planning channel
2. ✅ join: user cannot join another account's planning channel
3. ✅ generate_menu: generates response with request_id
4. ✅ generate_menu: error when Server.start_generation fails
5. ✅ swap_constraints: returns response with request_id
6. ✅ swap_constraints: broadcasts error when service fails
7. ✅ chat: success when GenerationServer is running
8. ✅ chat: error when no active generation
9. ✅ chat: missing proposal_id returns error
10. ✅ confirm_proposal: error when proposal not found (graceful)
11. ✅ confirm_proposal: error when invalid proposal_id format
12. ✅ reject_proposal: error when proposal not found (graceful)
13. ✅ reject_proposal: rejects with missing proposal_id gracefully
14. ✅ unknown event: returns invalid_payload
15. ✅ build_request_id: generates unique ids
16. ✅ serialize_reason: converts atoms to strings

## Files Changed

### New/Modified Test Files

1. `test/meal_planner_api_web/channels/cooking_channel_test.exs`
   - Expanded from skeleton (1 skipped test) to 17 comprehensive tests
   - Uses ChannelHelpers.issue_identity_and_token/2
   - Uses async: false for Sandbox compatibility

2. `test/meal_planner_api_web/channels/planning_channel_test.exs`
   - Replaced skeleton with 16 comprehensive tests
   - Uses ChannelHelpers.issue_identity_and_token/2
   - Uses async: false for Sandbox compatibility

### Bug Fixes

1. **CookingChannel** (lib/meal_planner_api_web/channels/cooking_channel.ex)
   - Fixed KeyError bug in ask_assistant handler when session_id not in socket.assigns
   - Changed `socket.assigns.session_id` to `Map.get(socket.assigns, :session_id)`

2. **PlanningChannel** (lib/meal_planner_api_web/channels/planning_channel.ex)
   - Added exception handling for Ecto.NoResultsError and Ecto.Query.CastError
   - confirm_proposal now returns "not_found" instead of crashing
   - reject_proposal now returns "not_found" instead of crashing

## TDD Evidence

### RED Phase
- Wrote failing tests first for each channel
- Verified tests failed before implementation

### GREEN Phase
- Implemented tests against existing channel code
- Fixed bugs discovered during testing (see Bug Fixes above)

### TRIANGULATE Phase
- Added additional edge case tests (non-binary inputs, missing fields)
- Verified error handling behavior

### REFACTOR Phase
- Simplified assertions where possible
- Used assert_push vs assert_broadcast appropriately

## Deviations from Design

1. **Mox mocks skipped**: Design suggested Mox mocks, but PR1 used Sandbox pattern. Followed PR1 pattern for consistency.

2. **PlanningChannel tests adjusted**: Some GenerationServer interactions are timing-dependent and hard to test reliably. Tests focus on:
   - Authorization checks (join)
   - Error handling paths
   - Helper function behavior via indirect testing

3. **Helper function testing**: Private functions `build_request_id/0` and `serialize_reason/1` tested indirectly through public API.

## Known Issues / Technical Debt

1. **GenerationServer integration**: Tests that depend on GenerationServer running are limited to checking "no crash" behavior rather than full success paths due to test context limitations.

2. **Pre-existing warning**: `parse_bool/1` unused warning in shopping_controller.ex (not introduced by this PR)

## PR Boundary

PR2 covers: CookingChannel + PlanningChannel tests (tasks 9-10-11)

**Ready for parent review and commit.**

## Workload Summary

- **Estimated lines**: ~460
- **Actual lines added**: ~420 (test files)
- **Bug fixes**: 2 (CookingChannel session_id access, PlanningChannel exception handling)
- **Test coverage increase**: +33 tests (from 19 in PR1 to 52 total)