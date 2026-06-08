

Now I have the format. Let me write the PROPOSAL.md:

```markdown
# SDD: Phoenix Channels Test Coverage

## Metadata
- **Change ID**: channels-test-coverage
- **Created**: 2026-06-07
- **Author**: SDD Explore Executor
- **Status**: proposal

## Problem Statement

All 4 Phoenix Channels in the project have 0% test coverage. Two test files exist but contain only skeleton/broken tests:
- `cooking_channel_test.exs` — 1 test, always skipped (`@tag :skip`)
- `planning_channel_test.exs` — only checks module existence, no actual behavior tests
- `ai_channel_test.exs` — does not exist
- `calendar_channel_test.exs` — does not exist

This leaves critical real-time functionality completely untested.

## Scope

### In Scope
- Unit/integration tests for all 4 Phoenix Channels
- Join authorization tests (account_id matching)
- handle_in event tests (success and failure paths)
- Broadcast event verification
- Socket assigns verification
- Payload validation edge cases

### Out of Scope
- Testing the external services called by channels (AI, CookingService, PlanningChatService, Calendar)
- Integration tests that span multiple channels
- E2E WebSocket tests from client perspective

## Channel Exploration Results

### Summary Table

| Channel | handle_in events | broadcast/push events | socket assigns | test file exists? |
|---------|------------------|-----------------------|---------------|-------------------|
| AI | `new_message` (guarded: binary message required) | via `AI.stream_response` (external), pushes `ai_response_error` | `room_id` | **no** |
| Calendar | `toggle_favorite`, `upsert_meal`, `delete_meal`, `set_is_cooked`, fallback to invalid_payload | `favorite_toggled`, `meal_updated`, `meal_deleted`, `meal_cooked_state_changed` | `account_id` | **no** |
| Cooking | `start_session`, `get_state`, `track_step`, `finish_session`, `ask_assistant`, fallback to event_not_implemented | `session_started`, `step_tracked`, `session_finished`, `assistant_reply` | none | **yes** (1 skipped) |
| Planning | `generate_menu`, `swap_constraints`, `chat`, `confirm_proposal`, `reject_proposal`, fallback to invalid_payload | `generation_started`, `proposal_ready`, `proposal_confirmed`, `proposal_rejected`, `generation_error` | `account_id` | **yes** (skeleton only) |

### Detailed Channel Analysis

#### 1. AIChannel (`ai_chat:<room_id>`)

**File**: `lib/meal_planner_api_web/channels/ai_channel.ex`

**Join**:
- Pattern: `"ai_chat:" <> room_id`
- No authorization check (any authenticated user can join any room)
- Assigns `room_id`

**handle_in events**:
| Event | Payload | Success path | Failure path |
|-------|---------|--------------|--------------|
| `new_message` | `%{"message" => message, ...}` | Guard: `is_binary(message)`, calls `AI.stream_response`, `{:noreply, socket}` | Missing/invalid message → `{:reply, {:error, %{reason: "invalid_payload"}}, socket}` |
| `new_message` | anything else | — | `{:reply, {:error, %{reason: "invalid_payload"}}, socket}` |

**External deps**: `MealPlannerApi.AI.stream_response/4`

**Test cases needed**:
1. Join succeeds, `room_id` assigned
2. `new_message` with valid binary message → calls AI.stream_response
3. `new_message` with non-binary message → error reply
4. `new_message` with missing `message` key → error reply
5. AI.stream_response returns `{:error, reason}` → pushes `ai_response_error`, error reply

---

#### 2. CalendarChannel (`calendar:<account_id>`)

**File**: `lib/meal_planner_api_web/channels/calendar_channel.ex`

**Join**:
- Pattern: `"calendar:" <> account_id`
- Authorization: `user.account_id == account_id` → ok, else `{:error, %{reason: "forbidden"}}`
- Assigns `account_id`

**handle_in events**:
| Event | Payload | Success path | Broadcast | Failure path |
|-------|---------|--------------|-----------|--------------|
| `toggle_favorite` | `%{"recipe_id" => recipe_id}` guard: `is_binary(recipe_id)` | Calls `Calendar.toggle_favorite`, replies `{:ok, is_favorite}` | `favorite_toggled` (user_id, recipe_id, is_favorite) | error reply |
| `upsert_meal` | any | Parses date + slot, calls `Calendar.upsert_scheduled_meal` | `meal_updated` | error reply with reason |
| `delete_meal` | any | Parses date + slot, calls `Calendar.delete_scheduled_meal` | `meal_deleted` | error reply with reason |
| `set_is_cooked` | `%{"meal_id", "is_cooked"}` | Calls `Calendar.set_is_cooked` | `meal_cooked_state_changed` | error reply with reason |
| fallback | — | — | — | `{:reply, {:error, %{reason: "invalid_payload"}}, socket}` |

**Helper functions** (need testing):
- `parse_date/1` — ISO 8601 format, returns `{:ok, date}` or `{:error, "invalid_date_format"}`
- `parse_slot/1` — "breakfast", "lunch", "snack", "dinner" → atoms, else `{:error, "invalid_slot"}`
- `upsert_attrs/3` — merges payload into map

**External deps**: `MealPlannerApi.Persistence.Calendar`

**Test cases needed**:
1. Join with matching account_id → ok
2. Join with mismatched account_id → forbidden error
3. `toggle_favorite` success → reply + broadcast
4. `toggle_favorite` with non-binary recipe_id → error
5. `upsert_meal` with valid payload → reply + broadcast
6. `upsert_meal` with invalid date format → error
7. `upsert_meal` with invalid slot → error
8. `delete_meal` success → reply + broadcast
9. `delete_meal` not found → error
10. `set_is_cooked` success → reply + broadcast
11. `set_is_cooked` with non-boolean is_cooked → error
12. `set_is_cooked` with missing meal_id → error
13. Unknown event → invalid_payload error

---

#### 3. CookingChannel (`cooking:<account_and_session>`)

**File**: `lib/meal_planner_api_web/channels/cooking_channel.ex`

**Join**:
- Pattern: `"cooking:" <> _account_and_session`
- No authorization (anyone authenticated)
- No socket assigns

**handle_in events**:
| Event | Payload | Success path | Push | Failure path |
|-------|---------|--------------|------|--------------|
| `start_session` | `%{"scheduled_meal_id" => meal_id}` guard: `is_binary(meal_id)` | Calls `CookingService.start_session` | `session_started` | error reply |
| `get_state` | `%{"session_id" => session_id}` guard: `is_binary(session_id)` | Calls `CookingService.session_state` | — | error reply |
| `track_step` | `%{"session_id", "recipe_step_id", "status", ...}` | Calls `CookingService.track_step` | `step_tracked` | error reply |
| `finish_session` | `%{"session_id" => session_id}` guard: `is_binary(session_id)` | Calls `CookingService.finish_session` | `session_finished` | error reply |
| `ask_assistant` | `%{"message" => message}` guard: `is_binary(message)` | Calls `CookingService.answer_question` | `assistant_reply` | error reply |
| fallback | — | — | — | `{:reply, {:error, %{reason: "event_not_implemented"}}, socket}` |

**Status enum**: "started", "paused", "completed", "error" (defaults to `:started`)

**External deps**: `MealPlannerApi.Services.CookingService`

**Existing test**: `test/meal_planner_api_web/channels/cooking_channel_test.exs` — 1 skipped test for `ask_assistant` streaming

**Test cases needed**:
1. Join succeeds
2. `start_session` with valid meal_id → push session_started
3. `start_session` with missing/invalid meal_id → error
4. `get_state` with valid session_id → reply with state
5. `get_state` with missing session_id → error
6. `track_step` with all fields → push step_tracked
7. `track_step` status enum mapping (started/paused/completed/error)
8. `track_step` with extra fields passed through
9. `track_step` with missing fields → error
10. `finish_session` success → push session_finished
11. `finish_session` with missing session_id → error
12. `ask_assistant` with active session → push assistant_reply
13. `ask_assistant` with no session_id and no socket session_id → error "no_active_session"
14. `ask_assistant` uses socket.assigns.session_id when payload has no session_id
15. Unknown event → event_not_implemented error

---

#### 4. PlanningChannel (`planning:<account_id>`)

**File**: `lib/meal_planner_api_web/channels/planning_channel.ex`

**Join**:
- Pattern: `"planning:" <> account_id`
- Authorization: `user.account_id == account_id` → ok, else `{:error, %{reason: "forbidden"}}`
- Assigns `account_id`

**handle_in events**:
| Event | Payload | Success path | Broadcast | Failure path |
|-------|---------|--------------|-----------|--------------|
| `generate_menu` | any (constraints from payload) | Calls `Server.start_generation` | `generation_started` | error reply |
| `swap_constraints` | `%{"constraints", "base_payload", ...}` | Calls `PlanningChatService.regenerate_menu` | `proposal_ready` | error broadcast |
| `chat` | `%{"message", "proposal_id"}` guard: `is_binary(message)` | Looks up GenServer, calls `Server.chat` | — | error reply |
| `confirm_proposal` | `%{"proposal_id" => proposal_id}` | Tries GenServer first, falls back to `PlanningChatService` | `proposal_confirmed` (fallback only) | error reply |
| `reject_proposal` | `%{"proposal_id" => proposal_id}` | Tries GenServer first, falls back to `PlanningChatService` | `proposal_rejected` (fallback only) | error reply |
| fallback | — | — | — | `{:reply, {:error, %{reason: "invalid_payload"}}, socket}` |

**Helper functions** (need testing):
- `build_request_id/0` — returns `"req_" <> unique_integer`
- `serialize_reason/1` — atom → string, binary → binary, else → "invalid_payload"

**External deps**: `MealPlannerApi.Generation.Server`, `MealPlannerApi.Services.PlanningChatService`

**Existing test**: `test/meal_planner_api_web/channels/planning_channel_test.exs` — only checks module existence

**Test cases needed**:
1. Join with matching account_id → ok
2. Join with mismatched account_id → forbidden error
3. `generate_menu` success → broadcast generation_started, reply with request_id/run_id
4. `generate_menu` when already running → error "generation_in_progress"
5. `generate_menu` when server returns other error → broadcast generation_error, error reply
6. `swap_constraints` success → broadcast proposal_ready
7. `swap_constraints` failure → broadcast generation_error
8. `chat` when GenServer exists → noreply (GenServer handles response)
9. `chat` when no GenServer → error "no_active_generation"
10. `confirm_proposal` via GenServer → reply with result
11. `confirm_proposal` fallback to PlanningChatService → broadcast proposal_confirmed
12. `confirm_proposal` fallback failure → error reply
13. `reject_proposal` via GenServer → noreply
14. `reject_proposal` fallback → broadcast proposal_rejected
15. Unknown event → invalid_payload error
16. `build_request_id/0` format: starts with "req_", followed by integer
17. `serialize_reason/1` handles atoms, binaries, and other values

---

## Patterns Across All Channels

### Shared Test Infrastructure
1. **Authentication**: All channels require JWT via `UserSocket.connect/3`. Tests must use `connect(UserSocket, %{"token" => token})` pattern.
2. **Authorization in join**: Calendar and Planning check `user.account_id == account_id`. AI and Cooking do not authorize on join.
3. **Payload guards**: Each channel has multiple `handle_in` clauses with guards for type checking (binary strings, booleans).
4. **Error reply format**: All channels use `{:reply, {:error, %{reason: "..."}}, socket}` for error replies.
5. **Noreply pattern**: Channels that delegate to external processes (AI, Planning.chat) use `{:noreply, socket}`.

### Shared Test Utilities
- `issue_identity_and_token/2` helper (already exists in cooking_channel_test.exs) — should be extracted to ChannelCase or a shared helper
- `ChannelCase` already sets up DB sandbox and subscription plan fixtures

### Mocks Needed
| Channel | External calls to mock |
|---------|----------------------|
| AIChannel | `AI.stream_response/4` |
| CalendarChannel | `Calendar.toggle_favorite/3`, `Calendar.upsert_scheduled_meal/2`, `Calendar.delete_scheduled_meal/3`, `Calendar.set_is_cooked/3` |
| CookingChannel | `CookingService.start_session/2`, `CookingService.session_state/2`, `CookingService.track_step/5`, `CookingService.finish_session/2`, `CookingService.answer_question/4` |
| PlanningChannel | `Server.start_generation/4`, `Server.chat/3`, `Server.confirm/2`, `Server.reject/2`, `PlanningChatService.regenerate_menu/3`, `PlanningChatService.confirm_proposal/2`, `PlanningChatService.reject_proposal/2` |

## Testing Strategy

### 1. Create shared test helper
Extract `issue_identity_and_token/2` from `cooking_channel_test.exs` to `test/support/channel_helpers.ex` for reuse across all channel tests.

### 2. Test file structure

```
test/meal_planner_api_web/channels/
├── ai_channel_test.exs         (new)
├── calendar_channel_test.exs   (new)
├── cooking_channel_test.exs    (expand existing, remove @tag :skip)
├── planning_channel_test.exs    (expand existing)
└── channel_helpers.exs         (new shared helper)
```

### 3. Mock approach
Use `Mox` for defining mocks in tests, with `with_mock` or `Mox.expect` patterns. Each channel test module defines its own mocks for its external dependencies.

### 4. Test categories per channel
- **join tests**: authorization success/failure
- **event tests**: each handle_in event with valid and invalid payloads
- **broadcast tests**: verify correct broadcasts are sent with correct payloads
- **socket assigns tests**: verify assigns are set correctly after join

## Dependencies
- `Phoenix.ChannelTest` — already available via ChannelCase
- `Mox` — needs to be checked if already in mix.exs deps
- `MealPlannerApi.Auth.Guardian` — for token generation in tests
- Existing ChannelCase setup (DB sandbox, subscription plans)

## Risks
- **Medium risk**: AI channel tests require mocking an external streaming service — need to verify mock behavior matches actual streaming
- **Medium risk**: Planning channel tests require Registry lookups — GenServer must be started in test environment
- **Low risk**: Calendar/Planning authorization tests are straightforward

## Open Questions
1. Should Mox be added as a test dependency, or use Elixir's built-in mock patterns?
2. Should channel tests be tagged `:async: false` given they use DB sandbox?
3. Should we test the broadcast delivery to other clients (multi-socket), or only single-socket behavior?
```