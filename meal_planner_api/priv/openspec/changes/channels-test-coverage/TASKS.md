# TASKS: Phoenix Channels Test Coverage

## Metadata
- **Change ID**: channels-test-coverage
- **Status**: tasks
- **Created**: 2026-06-07

---

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~700 total |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | 2 PRs (PR1: AI + Calendar, PR2: Cooking + Planning + shared helper) |
| Delivery strategy | ask-on-risk |
| Chain strategy | stacked-to-main |

```text
Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High
```

### Rationale

The total scope is ~700 lines across 4 test files plus shared infrastructure. This exceeds the 400-line review budget. Splitting into 2 PRs allows:
- PR1 (~250 lines): AI + Calendar channels with Mox setup
- PR2 (~450 lines): Cooking + Planning channels + shared helper

Both PRs share the same dependency (Mox + ChannelHelpers), so they must be stacked with PR1 merged first.

---

## PR1 — AI + Calendar channels

**Estimated lines**: ~240 (AI: ~60, Calendar: ~180)
**Files touched**:
- `mix.exs` (add Mox)
- `test/test_helper.exs` (Mox definitions)
- `test/support/channel_helpers.ex` (new)
- `test/support/channel_case.ex` (import ChannelHelpers)
- `test/meal_planner_api_web/channels/ai_channel_test.exs` (new)
- `test/meal_planner_api_web/channels/calendar_channel_test.exs` (new)

---

### TASK-1: Add Mox dependency and configure

**File**: `meal_planner_api/mix.exs`
**Estimated lines**: ~5

**Steps**:
1. Add `{:mox, "~> 1.1", only: :test}` to `deps/0` function
2. Run `mix deps.get` to install

**Verification**: `mix deps.get` completes without error

---

### TASK-2: Create ChannelHelpers shared test module

**File**: `test/support/channel_helpers.ex`
**Estimated lines**: ~30

**Steps**:
1. Create `test/support/channel_helpers.ex` with `issue_identity_and_token/2` function
2. Extract logic from existing `cooking_channel_test.exs` helper
3. Function should:
   - Accept `user_id` and `account_id` strings
   - Call `Accounts.find_or_create_identity/1`
   - Generate JWT via `Guardian.encode_and_sign/3`
   - Return `{:ok, user, account, token}`

**Verification**: Module compiles, function returns expected tuple

---

### TASK-3: Update ChannelCase to import ChannelHelpers

**File**: `test/support/channel_case.ex`
**Estimated lines**: ~3

**Steps**:
1. Add `import MealPlannerApiWeb.ChannelHelpers` to the `using` block

**Verification**: `mix compile` succeeds

---

### TASK-4: Add Mox definitions to test_helper.exs

**File**: `test/test_helper.exs`
**Estimated lines**: ~15

**Steps**:
1. Add `Mox.definitions/1` calls for all mock modules:
   - `MealPlannerApi.AI.Mock`
   - `MealPlannerApi.Persistence.Calendar.Mock`

**Verification**: Tests can use `Mox` without errors

---

### TASK-5: Write AIChannel tests

**File**: `test/meal_planner_api_web/channels/ai_channel_test.exs`
**Estimated lines**: ~60
**Test cases**: 5

**Steps**:
1. Create test module with `use MealPlannerApiWeb.ChannelCase, async: false`
2. Import `Mox`, set up `set_mox_from_context` and `verify_on_exit!`
3. Import `ChannelHelpers` for token generation
4. Write test cases:

| Test | Description |
|------|-------------|
| TC-1 | `join/3`: authenticated user joins valid AI room → `{:ok, socket}` with `room_id` assigned |
| TC-2 | `join/3`: join without token → `{:error, :unauthenticated}` |
| TC-3 | `new_message`: valid binary message → calls `AI.stream_response/4`, `{:noreply, socket}` |
| TC-4 | `new_message`: missing `message` field → `{:error, %{reason: "invalid_payload"}}` |
| TC-5 | `new_message`: non-binary message (int/list) → `{:error, %{reason: "invalid_payload"}}` |
| TC-6 | `new_message`: AI.stream_response returns error → pushes `ai_response_error`, error reply |

**Mock setup**:
- Mock `AI.Mock` for `stream_response/4` returning `:ok` or `{:error, reason}`

**Verification**: `mix test test/meal_planner_api_web/channels/ai_channel_test.exs`

---

### TASK-6: Write CalendarChannel tests

**File**: `test/meal_planner_api_web/channels/calendar_channel_test.exs`
**Estimated lines**: ~180
**Test cases**: 13

**Steps**:
1. Create test module with `use MealPlannerApiWeb.ChannelCase, async: false`
2. Import `Mox`, set up `set_mox_from_context` and `verify_on_exit!`
3. Write test cases organized by event:

**Join authorization (2 tests)**:
| Test | Description |
|------|-------------|
| TC-1 | User joins their own calendar → success, `account_id` assigned |
| TC-2 | User cannot join another user's calendar → `{:error, %{reason: "forbidden"}}` |

**toggle_favorite event (3 tests)**:
| Test | Description |
|------|-------------|
| TC-3 | Success → calls `Calendar.toggle_favorite/3`, reply with `is_favorite`, broadcast `favorite_toggled` |
| TC-4 | Non-binary `recipe_id` → error reply |
| TC-5 | Missing `recipe_id` → error reply |

**upsert_meal event (3 tests)**:
| Test | Description |
|------|-------------|
| TC-6 | Valid ISO 8601 date + slot → calls `Calendar.upsert_scheduled_meal/2`, reply, broadcast `meal_updated` |
| TC-7 | Invalid date format → `{:error, %{reason: "invalid_date_format"}}` |
| TC-8 | Invalid slot → `{:error, %{reason: "invalid_slot"}}` |

**delete_meal event (2 tests)**:
| Test | Description |
|------|-------------|
| TC-9 | Success → calls `Calendar.delete_scheduled_meal/3`, reply, broadcast `meal_deleted` |
| TC-10 | Not found → `{:error, %{reason: "not_found"}}` |

**set_is_cooked event (3 tests)**:
| Test | Description |
|------|-------------|
| TC-11 | Boolean `is_cooked` → calls `Calendar.set_is_cooked/3`, reply, broadcast `meal_cooked_state_changed` |
| TC-12 | Non-boolean `is_cooked` → error reply |
| TC-13 | Missing `meal_id` → error reply |

**Unknown event (1 test)**:
| Test | Description |
|------|-------------|
| TC-14 | Unknown event → `{:error, %{reason: "invalid_payload"}}` |

**Mock setup**:
- Mock `Calendar.Mock` for all4 functions with appropriate return values

**Verification**: `mix test test/meal_planner_api_web/channels/calendar_channel_test.exs`

---

### TASK-7: Verify PR1 — Run AI + Calendar tests

**Command**: `mix test test/meal_planner_api_web/channels/ai_channel_test.exs test/meal_planner_api_web/channels/calendar_channel_test.exs`

**Success criteria**: All tests pass (18 total)

---

## PR 2 — Cooking + Planning channels + shared infrastructure

**Estimated lines**: ~460 (Cooking: ~200, Planning: ~220, mocks: ~40)
**Files touched**:
- `test/support/mocks/ai_mock.ex` (new)
- `test/support/mocks/calendar_mock.ex` (new)
- `test/support/mocks/cooking_service_mock.ex` (new)
- `test/support/mocks/server_mock.ex` (new)
- `test/support/mocks/planning_chat_service_mock.ex` (new)
- `test/meal_planner_api_web/channels/cooking_channel_test.exs` (expand)
- `test/meal_planner_api_web/channels/planning_channel_test.exs` (expand)

**Dependencies**: PR1 must be merged first

---

### TASK-8: Create Mox mock modules

**Files**: `test/support/mocks/*.ex` (5 files)
**Estimated lines**: ~40 total

**Steps**:
1. Create `test/support/mocks/ai_mock.ex` — mock for `AI.stream_response/4`
2. Create `test/support/mocks/calendar_mock.ex` — mock for Calendar functions
3. Create `test/support/mocks/cooking_service_mock.ex` — mock for CookingService functions
4. Create `test/support/mocks/server_mock.ex` — mock for Server GenServer functions
5. Create `test/support/mocks/planning_chat_service_mock.ex` — mock for PlanningChatService functions

**Note**: Mox requires explicit module definitions for each mock. Use `Mox.defmock/2` in test_helper.exs or define modules with `use Mox`.

**Verification**: All mock modules compile

---

### TASK-9: Expand CookingChannel tests

**File**: `test/meal_planner_api_web/channels/cooking_channel_test.exs`
**Estimated lines**: ~200
**Test cases**: 15
**Dependencies**: TASK-8

**Steps**:
1. Remove `@tag :skip` from existing test
2. Add Mox setup (`import Mox`, `setup :set_mox_from_context`, `setup :verify_on_exit!`)
3. Update to use `ChannelHelpers.issue_identity_and_token/2`
4. Write test cases organized by event:

**Join (1 test)**:
| Test | Description |
|------|-------------|
| TC-1 | Authenticated user joins cooking session → success, no `account_id` assign |

**start_session event (3 tests)**:
| Test | Description |
|------|-------------|
| TC-2 | Valid `meal_id` → calls `CookingService.start_session/2`, reply, push `session_started` |
| TC-3 | Missing `meal_id` → error reply |
| TC-4 | Non-binary `meal_id` → error reply |

**get_state event (2 tests)**:
| Test | Description |
|------|-------------|
| TC-5 | Valid `session_id` → calls `CookingService.session_state/2`, reply with state |
| TC-6 | Missing `session_id` → error reply |

**track_step event (4 tests)**:
| Test | Description |
|------|-------------|
| TC-7 | All required fields + extra → calls `CookingService.track_step/5`, reply, push `step_tracked` |
| TC-8 | Status enum mapping: "started", "paused", "completed", "error" → correct atoms passed |
| TC-9 | Missing required fields → error reply |
| TC-10 | Extra fields passed through to service |

**finish_session event (2 tests)**:
| Test | Description |
|------|-------------|
| TC-11 | Success → calls `CookingService.finish_session/2`, reply, push `session_finished` |
| TC-12 | Missing `session_id` → error reply |

**ask_assistant event (4 tests)**:
| Test | Description |
|------|-------------|
| TC-13 | Explicit `session_id` → calls `CookingService.answer_question/4`, reply, push `assistant_reply` |
| TC-14 | No `session_id` in payload, uses socket `session_id` → fallback works |
| TC-15 | No session available → `{:error, %{reason: "no_active_session"}}` |
| TC-16 | Non-binary message → error reply |

**Unknown event (1 test)**:
| Test | Description |
|------|-------------|
| TC-17 | Unknown event → `{:error, %{reason: "event_not_implemented"}}` |

**Mock setup**:
- Mock `CookingService.Mock` for all 5 functions

**Verification**: `mix test test/meal_planner_api_web/channels/cooking_channel_test.exs`

---

### TASK-10: Expand PlanningChannel tests

**File**: `test/meal_planner_api_web/channels/planning_channel_test.exs`
**Estimated lines**: ~220
**Test cases**: 17
**Dependencies**: TASK-8

**Steps**:
1. Replace skeleton test file with full Mox-based tests
2. Add Mox setup (`import Mox`, `setup :set_mox_from_context`, `setup :verify_on_exit!`)
3. Update to use `ChannelHelpers.issue_identity_and_token/2`
4. Write test cases organized by event:

**Join authorization (2 tests)**:
| Test | Description |
|------|-------------|
| TC-1 | User joins their own planning channel → success, `account_id` assigned |
| TC-2 | User cannot join another user's planning channel → `{:error, %{reason: "forbidden"}}` |

**generate_menu event (3 tests)**:
| Test | Description |
|------|-------------|
| TC-3 | Success → calls `Server.start_generation/4`, broadcast `generation_started`, reply with request_id/run_id |
| TC-4 | Already running → `{:error, %{reason: "generation_in_progress"}}` |
| TC-5 | Server error → broadcast `generation_error`, error reply |

**swap_constraints event (2 tests)**:
| Test | Description |
|------|-------------|
| TC-6 | Success → calls `PlanningChatService.regenerate_menu/3`, broadcast `proposal_ready` |
| TC-7 | Failure → broadcast `generation_error` |

**chat event (3 tests)**:
| Test | Description |
|------|-------------|
| TC-8 | GenServer exists → calls `Server.chat/3`, `{:noreply, socket}` |
| TC-9 | No GenServer → `{:error, %{reason: "no_active_generation"}}` |
| TC-10 | Non-binary message → error reply |

**confirm_proposal event (3 tests)**:
| Test | Description |
|------|-------------|
| TC-11 | Via GenServer → calls `Server.confirm/2`, reply with result |
| TC-12 | Fallback to PlanningChatService → broadcast `proposal_confirmed` |
| TC-13 | Fallback failure → error reply |

**reject_proposal event (2 tests)**:
| Test | Description |
|------|-------------|
| TC-14 | Via GenServer → calls `Server.reject/2`, `{:noreply, socket}` |
| TC-15 | Fallback → broadcast `proposal_rejected` |

**Unknown event (1 test)**:
| Test | Description |
|------|-------------|
| TC-16 | Unknown event → `{:error, %{reason: "invalid_payload"}}` |

**Helper functions (4 tests)**:
| Test | Description |
|------|-------------|
| TC-17 | `build_request_id/0` → starts with "req_", followed by integer |
| TC-18 | `build_request_id/0` → generates unique IDs |
| TC-19 | `serialize_reason/1` → handles atoms → string |
| TC-20 | `serialize_reason/1` → handles binaries → unchanged |
| TC-21 | `serialize_reason/1` → handles unknown types → "invalid_payload" |

**Mock setup**:
- Mock `Server.Mock` for GenServer functions
- Mock `PlanningChatService.Mock` for fallback service functions
- Set up Registry entries for GenServer tests (cleanup in `after` block)

**Verification**: `mix test test/meal_planner_api_web/channels/planning_channel_test.exs`

---

### TASK-11: Verify PR2 — Run full channel test suite

**Command**: `mix test test/meal_planner_api_web/channels/`

**Success criteria**: All channel tests pass

---

## Task Dependency Graph

```
TASK-1 (Mox dep)
    ↓
TASK-2 (ChannelHelpers) ──┐
    ↓                     │
TASK-3 (ChannelCase)      │
    ↓                     │
TASK-4 (Mox defs)         │
    ↓                     │
TASK-5 (AI tests)         │
    ↓                     │
TASK-6 (Calendar tests)   │
    ↓ │
TASK-7 (PR1 verify) ───────┘
 ↓
[PR1 MERGE]
 ↓
TASK-8 (Mox mocks) ────────┐
    ↓                     │
TASK-9 (Cooking tests)    │
    ↓                     │
TASK-10 (Planning tests)  │
    ↓                     │
TASK-11 (PR2 verify) ─────┘
```

---

## Verification Commands

After each task:

```bash
# TASK-1
mix deps.get

# TASK-2, TASK-3
mix compile

# TASK-5
mix test test/meal_planner_api_web/channels/ai_channel_test.exs

# TASK-6
mix test test/meal_planner_api_web/channels/calendar_channel_test.exs

# TASK-7 (PR1 final)
mix test test/meal_planner_api_web/channels/ai_channel_test.exs \
 test/meal_planner_api_web/channels/calendar_channel_test.exs

# TASK-9
mix test test/meal_planner_api_web/channels/cooking_channel_test.exs

# TASK-10
mix test test/meal_planner_api_web/channels/planning_channel_test.exs

# TASK-11 (PR2 final / full suite)
mix test test/meal_planner_api_web/channels/
```

---

## Rollback Plan

If any task fails verification:

1. **TASK-1 (Mox)**: Remove `{:mox, "~> 1.1", only: :test}` from `mix.exs`, run `mix deps.clean --unlock mox`
2. **TASK-2 (ChannelHelpers)**: Delete `test/support/channel_helpers.ex`
3. **TASK-3 (ChannelCase)**: Revert import line
4. **TASK-4 (Mox defs)**: Remove Mox definitions from `test_helper.exs`
5. **TASK-5, TASK-6, TASK-9, TASK-10**: Delete test file, revert to previous state
6. **TASK-8 (Mox mocks)**: Delete `test/support/mocks/` directory

---

## Acceptance Criteria

- [ ] Mox added to `mix.exs` deps
- [ ] `ChannelHelpers.issue_identity_and_token/2` created and used by all channel tests
- [ ] `ChannelCase` imports `ChannelHelpers`
- [ ] AIChannel tests: 6 test cases, all pass
- [ ] CalendarChannel tests: 14 test cases, all pass
- [ ] CookingChannel tests: 17 test cases, all pass (skip tag removed)
- [ ] PlanningChannel tests: 21 test cases, all pass
- [ ] All tests use `async: false` to avoid sandbox conflicts
- [ ] All external dependencies mocked with Mox
- [ ] `mix test test/meal_planner_api_web/channels/` passes with 0 failures
