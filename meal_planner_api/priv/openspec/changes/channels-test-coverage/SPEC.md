# SPEC: Phoenix Channels Test Coverage

## Metadata
- **Change ID**: channels-test-coverage
- **Created**: 2026-06-07
- **Author**: SDD Executor
- **Status**: spec

## Overview

This specification defines the test coverage requirements for all 4 Phoenix Channels in the MealPlannerApiWeb application. All tests MUST use the Phoenix.ChannelTest framework with Mox for external dependency mocking.

## Test File Structure

```
test/meal_planner_api_web/channels/
├── ai_channel_test.exs         (new)
├── calendar_channel_test.exs   (new)
├── cooking_channel_test.exs    (expand existing)
├── planning_channel_test.exs   (expand existing)
└── channel_helpers.exs         (new shared helper)
```

## Shared Test Infrastructure

### Requirement: ChannelHelpers module

The system MUST provide a shared `ChannelHelpers` module at `test/support/channel_helpers.ex` with the following function:

```elixir
@spec issue_identity_and_token(String.t(), String.t()) :: {:ok, User.t(), Account.t(), String.t()}
```

The function MUST:
- Accept `user_id` and `account_id` strings
- Call `Accounts.find_or_create_identity/1` to create or retrieve the identity
- Generate a valid JWT access token via `Guardian.encode_and_sign/3`
- Return `{:ok, user, account, token}` tuple

### Requirement: All channel tests use ChannelCase

All channel test modules MUST:
- Use `MealPlannerApiWeb.ChannelCase` as the base case (provides DB sandbox and subscription plan fixtures)
- Set `async: false` to avoid sandbox conflicts
- Import `ChannelHelpers` for token generation

---

## AIChannel Tests

**File**: `test/meal_planner_api_web/channels/ai_channel_test.exs` (new)

### Requirement: AIChannel join behavior

The system MUST verify the following for AIChannel join:

#### Scenario: Authenticated user joins valid AI room

- GIVEN a valid JWT token for any authenticated user
- WHEN the user joins topic `"ai_chat:<room_id>"`
- THEN the join MUST succeed with `{:ok, socket}`
- AND `socket.assigns.room_id` MUST equal the room_id from the topic

#### Scenario: Join without token

- GIVEN no token or invalid token
- WHEN the user attempts to join `"ai_chat:any_room"`
- THEN the join MUST fail with `{:error, :unauthenticated}`

### Requirement: AIChannel new_message event

The system MUST verify the following for `new_message` event handling:

#### Scenario: Valid message triggers AI.stream_response

- GIVEN a connected socket with `room_id` assigned
- WHEN the client pushes `"new_message"` with `%{"message" => "valid text", "request_id" => "req_1", "content_type" => "text"}`
- THEN the system MUST call `AI.stream_response/4` with:
  - `user_id` from `socket.assigns.current_user.id`
  - `room_id` from `socket.assigns.room_id`
  - `message` = `"valid text"`
  - options containing `request_id` and `content_type`
- AND the reply MUST be `{:noreply, socket}`

#### Scenario: Missing message field returns error

- GIVEN a connected socket
- WHEN the client pushes `"new_message"` with `%{}` or `%{"content" => "no message key"}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

#### Scenario: Non-binary message returns error

- GIVEN a connected socket
- WHEN the client pushes `"new_message"` with `%{"message" => 123}` or `%{"message" => ["list"]}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

#### Scenario: AI.stream_response error pushes ai_response_error

- GIVEN a connected socket
- AND `AI.stream_response/4` mocked to return `{:error, "rate_limit"}`
- WHEN the client pushes `"new_message"` with valid payload
- THEN the system MUST:
  - Reply with `{:reply, {:error, %{reason: "rate_limit"}}, socket}`
  - Push `"ai_response_error"` event to the socket with `reason: "rate_limit"`

---

## CalendarChannel Tests

**File**: `test/meal_planner_api_web/channels/calendar_channel_test.exs` (new)

### Requirement: CalendarChannel join authorization

The system MUST verify the following for CalendarChannel join:

#### Scenario: User joins their own calendar

- GIVEN a valid JWT token for user with `account_id`
- WHEN the user joins topic `"calendar:<account_id>"`
- THEN the join MUST succeed with `{:ok, socket}`
- AND `socket.assigns.account_id` MUST equal the account_id from the topic

#### Scenario: User cannot join another user's calendar

- GIVEN a valid JWT token for user with `account_id_A`
- WHEN the user attempts to join topic `"calendar:<account_id_B>"`
- THEN the join MUST be rejected with `{:error, %{reason: "forbidden"}}`

### Requirement: CalendarChannel toggle_favorite event

The system MUST verify the following for `toggle_favorite` event:

#### Scenario: Toggle favorite success

- GIVEN a connected socket with `account_id` assigned
- AND `Calendar.toggle_favorite/3` mocked to return `{:ok, true}`
- WHEN the client pushes `"toggle_favorite"` with `%{"recipe_id" => "recipe_123"}`
- THEN the system MUST:
  - Call `Calendar.toggle_favorite/3` with `account_id`, `user_id`, `"recipe_123"`
  - Reply with `{:reply, {:ok, %{is_favorite: true}}, socket}`
  - Broadcast `"favorite_toggled"` to `"calendar:<account_id>"` with `%{user_id: user_id, recipe_id: "recipe_123", is_favorite: true}`

#### Scenario: Toggle favorite with non-binary recipe_id

- GIVEN a connected socket
- WHEN the client pushes `"toggle_favorite"` with `%{"recipe_id" => 123}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

#### Scenario: Toggle favorite with missing recipe_id

- GIVEN a connected socket
- WHEN the client pushes `"toggle_favorite"` with `%{}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

### Requirement: CalendarChannel upsert_meal event

The system MUST verify the following for `upsert_meal` event:

#### Scenario: Upsert meal with valid ISO 8601 date

- GIVEN a connected socket with `account_id` assigned
- AND `Calendar.upsert_scheduled_meal/2` mocked to return `{:ok, meal_struct}`
- WHEN the client pushes `"upsert_meal"` with:
  ```json
  {
    "date": "2026-03-24",
    "slot": "lunch",
    "recipe_id": "recipe_456"
  }
  ```
- THEN the system MUST:
  - Call `Calendar.upsert_scheduled_meal/2` with `account_id` and parsed attributes
  - Reply with `{:reply, {:ok, meal_struct}, socket}`
  - Broadcast `"meal_updated"` with meal data

#### Scenario: Upsert meal with invalid date format

- GIVEN a connected socket
- WHEN the client pushes `"upsert_meal"` with `%{"date" => "invalid-date", "slot" => "lunch", "recipe_id" => "recipe_123"}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_date_format"}}, socket}`

#### Scenario: Upsert meal with invalid slot

- GIVEN a connected socket
- WHEN the client pushes `"upsert_meal"` with `%{"date" => "2026-03-24", "slot" => "invalid", "recipe_id" => "recipe_123"}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_slot"}}, socket}`

### Requirement: CalendarChannel delete_meal event

The system MUST verify the following for `delete_meal` event:

#### Scenario: Delete meal success

- GIVEN a connected socket with `account_id` assigned
- AND `Calendar.delete_scheduled_meal/3` mocked to return `:ok`
- WHEN the client pushes `"delete_meal"` with `%{"date" => "2026-03-24", "slot" => "lunch"}`
- THEN the system MUST:
  - Call `Calendar.delete_scheduled_meal/3` with `account_id`, date, and slot
  - Reply with `{:reply, :ok, socket}`
  - Broadcast `"meal_deleted"` with date and slot

#### Scenario: Delete meal not found

- GIVEN a connected socket
- AND `Calendar.delete_scheduled_meal/3` mocked to return `{:error, :not_found}`
- WHEN the client pushes `"delete_meal"` with valid date/slot
- THEN the system MUST reply with `{:reply, {:error, %{reason: "not_found"}}, socket}`

### Requirement: CalendarChannel set_is_cooked event

The system MUST verify the following for `set_is_cooked` event:

#### Scenario: Set is_cooked with boolean true

- GIVEN a connected socket with `account_id` assigned
- AND `Calendar.set_is_cooked/3` mocked to return `{:ok, updated_meal}`
- WHEN the client pushes `"set_is_cooked"` with `%{"meal_id" => "meal_789", "is_cooked" => true}`
- THEN the system MUST:
  - Call `Calendar.set_is_cooked/3` with `account_id`, `"meal_789"`, `true`
  - Reply with `{:reply, {:ok, updated_meal}, socket}`
  - Broadcast `"meal_cooked_state_changed"` with meal_id and is_cooked

#### Scenario: Set is_cooked with non-boolean value

- GIVEN a connected socket
- WHEN the client pushes `"set_is_cooked"` with `%{"meal_id" => "meal_789", "is_cooked" => "yes"}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

#### Scenario: Set is_cooked with missing meal_id

- GIVEN a connected socket
- WHEN the client pushes `"set_is_cooked"` with `%{"is_cooked" => true}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

### Requirement: CalendarChannel unknown event

#### Scenario: Unknown event returns invalid_payload

- GIVEN a connected socket
- WHEN the client pushes `"unknown_event"` with any payload
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

---

## CookingChannel Tests

**File**: `test/meal_planner_api_web/channels/cooking_channel_test.exs` (expand existing)

### Requirement: CookingChannel join behavior

The system MUST verify the following for CookingChannel join:

#### Scenario: Authenticated user joins cooking session

- GIVEN a valid JWT token for any authenticated user
- WHEN the user joins topic `"cooking:<account_id>:<session_id>"`
- THEN the join MUST succeed with `{:ok, socket}`
- AND `socket.assigns` MUST NOT contain `account_id` (no assigns set)

### Requirement: CookingChannel start_session event

The system MUST verify the following for `start_session` event:

#### Scenario: Start session with valid meal_id

- GIVEN a connected socket
- AND `CookingService.start_session/2` mocked to return `{:ok, %{session_id: "sess_123", steps: []}}`
- WHEN the client pushes `"start_session"` with `%{"scheduled_meal_id" => "meal_123"}`
- THEN the system MUST:
  - Call `CookingService.start_session/2` with `user_id`, `"meal_123"`
  - Reply with `{:reply, {:ok, session_data}, socket}`
  - Push `"session_started"` to the socket with session data

#### Scenario: Start session with missing meal_id

- GIVEN a connected socket
- WHEN the client pushes `"start_session"` with `%{}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

#### Scenario: Start session with non-binary meal_id

- GIVEN a connected socket
- WHEN the client pushes `"start_session"` with `%{"scheduled_meal_id" => 123}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

### Requirement: CookingChannel get_state event

The system MUST verify the following for `get_state` event:

#### Scenario: Get state with valid session_id

- GIVEN a connected socket
- AND `CookingService.session_state/2` mocked to return `{:ok, %{session_id: "sess_123", status: :active}}`
- WHEN the client pushes `"get_state"` with `%{"session_id" => "sess_123"}`
- THEN the system MUST:
  - Call `CookingService.session_state/2` with `user_id`, `"sess_123"`
  - Reply with `{:reply, {:ok, state_data}, socket}`

#### Scenario: Get state with missing session_id

- GIVEN a connected socket
- WHEN the client pushes `"get_state"` with `%{}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

### Requirement: CookingChannel track_step event

The system MUST verify the following for `track_step` event:

#### Scenario: Track step with all required fields

- GIVEN a connected socket
- AND `CookingService.track_step/5` mocked to return `{:ok, step_data}`
- WHEN the client pushes `"track_step"` with:
  ```json
  {
    "session_id": "sess_123",
    "recipe_step_id": "step_456",
    "status": "started",
    "extra_field": "passed_through"
  }
  ```
- THEN the system MUST:
  - Call `CookingService.track_step/5` with `user_id`, `"sess_123"`, `"step_456"`, `:started`, `%{"extra_field" => "passed_through"}`
  - Reply with `{:reply, :ok, socket}`
  - Push `"step_tracked"` to the socket with step data

#### Scenario: Track step with all status enum values

- GIVEN a connected socket
- AND `CookingService.track_step/5` mocked to return `{:ok, %{}}`
- WHEN the client pushes `"track_step"` with status values:
  - `"started"` → maps to `:started`
  - `"paused"` → maps to `:paused`
  - `"completed"` → maps to `:completed`
  - `"error"` → maps to `:error`
- THEN the system MUST call `CookingService.track_step/5` with the corresponding atom for each status

#### Scenario: Track step with missing required fields

- GIVEN a connected socket
- WHEN the client pushes `"track_step"` with `%{"session_id" => "sess_123"}` (missing `recipe_step_id` or `status`)
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

### Requirement: CookingChannel finish_session event

The system MUST verify the following for `finish_session` event:

#### Scenario: Finish session success

- GIVEN a connected socket
- AND `CookingService.finish_session/2` mocked to return `{:ok, %{session_id: "sess_123"}}`
- WHEN the client pushes `"finish_session"` with `%{"session_id" => "sess_123"}`
- THEN the system MUST:
  - Call `CookingService.finish_session/2` with `user_id`, `"sess_123"`
  - Reply with `{:reply, {:ok, result}, socket}`
  - Push `"session_finished"` to the socket

#### Scenario: Finish session with missing session_id

- GIVEN a connected socket
- WHEN the client pushes `"finish_session"` with `%{}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

### Requirement: CookingChannel ask_assistant event

The system MUST verify the following for `ask_assistant` event:

#### Scenario: Ask assistant with explicit session_id

- GIVEN a connected socket
- AND `CookingService.answer_question/4` mocked to return `{:ok, %{reply: "cooking tip"}}`
- WHEN the client pushes `"ask_assistant"` with:
  ```json
  {
    "request_id": "req_1",
    "message": "How do I know when sauce is ready?",
    "content_type": "text",
    "session_id": "sess_123"
  }
  ```
- THEN the system MUST:
  - Call `CookingService.answer_question/4` with `user_id`, `"sess_123"`, `"How do I know when sauce is ready?"`, options
  - Reply with `{:reply, :ok, socket}`
  - Push `"assistant_reply"` to the socket

#### Scenario: Ask assistant with socket session_id fallback

- GIVEN a connected socket with `session_id: "sess_from_socket"` assigned
- AND `CookingService.answer_question/4` mocked to return `{:ok, %{}}`
- WHEN the client pushes `"ask_assistant"` with:
  ```json
  {
    "request_id": "req_2",
    "message": "Next step?",
    "content_type": "text"
  }
  ```
- THEN the system MUST call `CookingService.answer_question/4` with session_id from socket assigns

#### Scenario: Ask assistant with no session_id available

- GIVEN a connected socket without `session_id` assigned
- WHEN the client pushes `"ask_assistant"` with `%{"message" => "hello", "request_id" => "req_3"}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "no_active_session"}}, socket}`
- AND MUST NOT call `CookingService.answer_question/4`

#### Scenario: Ask assistant with non-binary message

- GIVEN a connected socket with `session_id: "sess_123"` assigned
- WHEN the client pushes `"ask_assistant"` with `%{"message" => 123, "request_id" => "req_4"}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

### Requirement: CookingChannel unknown event

#### Scenario: Unknown event returns event_not_implemented

- GIVEN a connected socket
- WHEN the client pushes `"unknown_event"` with any payload
- THEN the system MUST reply with `{:reply, {:error, %{reason: "event_not_implemented"}}, socket}`

---

## PlanningChannel Tests

**File**: `test/meal_planner_api_web/channels/planning_channel_test.exs` (expand existing)

### Requirement: PlanningChannel join authorization

The system MUST verify the following for PlanningChannel join:

#### Scenario: User joins their own planning channel

- GIVEN a valid JWT token for user with `account_id`
- WHEN the user joins topic `"planning:<account_id>"`
- THEN the join MUST succeed with `{:ok, socket}`
- AND `socket.assigns.account_id` MUST equal the account_id from the topic

#### Scenario: User cannot join another user's planning channel

- GIVEN a valid JWT token for user with `account_id_A`
- WHEN the user attempts to join topic `"planning:<account_id_B>"`
- THEN the join MUST be rejected with `{:error, %{reason: "forbidden"}}`

### Requirement: PlanningChannel generate_menu event

The system MUST verify the following for `generate_menu` event:

#### Scenario: Generate menu success

- GIVEN a connected socket with `account_id` assigned
- AND `Server.start_generation/4` mocked to return `{:ok, %{run_id: "run_123", request_id: "req_gen_1"}}`
- WHEN the client pushes `"generate_menu"` with `%{"constraints" => %{}}`
- THEN the system MUST:
  - Call `Server.start_generation/4` with `account_id`, `user_id`, `"planning"`, constraints
  - Broadcast `"generation_started"` to `"planning:<account_id>"` with `request_id` and `run_id`
  - Reply with `{:reply, {:ok, %{request_id: "req_gen_1", run_id: "run_123"}}, socket}`

#### Scenario: Generate menu when already running

- GIVEN a connected socket
- AND `Server.start_generation/4` mocked to return `{:error, :already_running}`
- WHEN the client pushes `"generate_menu"` with any payload
- THEN the system MUST reply with `{:reply, {:error, %{reason: "generation_in_progress"}}, socket}`

#### Scenario: Generate menu when server returns other error

- GIVEN a connected socket
- AND `Server.start_generation/4` mocked to return `{:error, :timeout}`
- WHEN the client pushes `"generate_menu"` with any payload
- THEN the system MUST:
  - Broadcast `"generation_error"` to the channel
  - Reply with `{:reply, {:error, %{reason: "timeout"}}, socket}`

### Requirement: PlanningChannel swap_constraints event

The system MUST verify the following for `swap_constraints` event:

#### Scenario: Swap constraints success

- GIVEN a connected socket with `account_id` assigned
- AND `PlanningChatService.regenerate_menu/3` mocked to return `{:ok, %{proposal_id: "prop_swap_1"}}`
- WHEN the client pushes `"swap_constraints"` with:
  ```json
  {
    "constraints": {"dietary": "vegetarian"},
    "base_payload": {"date_range": "2026-03-24..2026-03-28"},
    "request_id": "req_swap_1"
  }
  ```
- THEN the system MUST:
  - Call `PlanningChatService.regenerate_menu/3` with `account_id`, user_id, payload
  - Broadcast `"proposal_ready"` to the channel with proposal data

#### Scenario: Swap constraints failure

- GIVEN a connected socket
- AND `PlanningChatService.regenerate_menu/3` mocked to return `{:error, :invalid_constraints}`
- WHEN the client pushes `"swap_constraints"` with valid payload
- THEN the system MUST broadcast `"generation_error"` to the channel

### Requirement: PlanningChannel chat event

The system MUST verify the following for `chat` event:

#### Scenario: Chat when GenServer exists

- GIVEN a connected socket with `account_id` assigned
- AND a running GenServer registered for the account
- AND `Server.chat/3` mocked to return `{:ok, %{response: "Here's a suggestion..."}}`
- WHEN the client pushes `"chat"` with:
  ```json
  {
    "message": "Can I swap pasta for rice?",
    "proposal_id": "prop_123",
    "request_id": "req_chat_1"
  }
  ```
- THEN the system MUST:
  - Call `Server.chat/3` with `account_id`, user_id, options
  - Reply with `{:noreply, socket}` (GenServer handles response)

#### Scenario: Chat when no GenServer exists

- GIVEN a connected socket
- AND Registry lookup returns no GenServer for the account
- WHEN the client pushes `"chat"` with `%{"message" => "hello", "request_id" => "req_chat_2"}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "no_active_generation"}}, socket}`

#### Scenario: Chat with non-binary message

- GIVEN a connected socket
- AND a running GenServer for the account
- WHEN the client pushes `"chat"` with `%{"message" => 123}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

### Requirement: PlanningChannel confirm_proposal event

The system MUST verify the following for `confirm_proposal` event:

#### Scenario: Confirm via GenServer

- GIVEN a connected socket with `account_id` assigned
- AND a running GenServer for the account
- AND `Server.confirm/2` mocked to return `{:ok, %{confirmed: true}}`
- WHEN the client pushes `"confirm_proposal"` with `%{"proposal_id" => "prop_123"}`
- THEN the system MUST:
  - Call `Server.confirm/2` with `account_id`, `"prop_123"`
  - Reply with `{:reply, {:ok, result}, socket}`

#### Scenario: Confirm via fallback service

- GIVEN a connected socket
- AND no GenServer for the account
- AND `PlanningChatService.confirm_proposal/2` mocked to return `{:ok, %{confirmed: true}}`
- WHEN the client pushes `"confirm_proposal"` with `%{"proposal_id" => "prop_456"}`
- THEN the system MUST:
  - Call `PlanningChatService.confirm_proposal/2` with `account_id`, `"prop_456"`
  - Broadcast `"proposal_confirmed"` to the channel
  - Reply with `{:reply, {:ok, %{confirmed: true}}, socket}`

#### Scenario: Confirm via fallback service failure

- GIVEN a connected socket
- AND no GenServer for the account
- AND `PlanningChatService.confirm_proposal/2` mocked to return `{:error, :not_found}`
- WHEN the client pushes `"confirm_proposal"` with `%{"proposal_id" => "invalid"}`
- THEN the system MUST reply with `{:reply, {:error, %{reason: "not_found"}}, socket}`

### Requirement: PlanningChannel reject_proposal event

The system MUST verify the following for `reject_proposal` event:

#### Scenario: Reject via GenServer

- GIVEN a connected socket with `account_id` assigned
- AND a running GenServer for the account
- AND `Server.reject/2` mocked to return `:ok`
- WHEN the client pushes `"reject_proposal"` with `%{"proposal_id" => "prop_123"}`
- THEN the system MUST:
  - Call `Server.reject/2` with `account_id`, `"prop_123"`
  - Reply with `{:noreply, socket}`

#### Scenario: Reject via fallback service

- GIVEN a connected socket
- AND no GenServer for the account
- AND `PlanningChatService.reject_proposal/2` mocked to return `:ok`
- WHEN the client pushes `"reject_proposal"` with `%{"proposal_id" => "prop_456"}`
- THEN the system MUST:
  - Broadcast `"proposal_rejected"` to the channel
  - Reply with `{:reply, :ok, socket}`

### Requirement: PlanningChannel unknown event

#### Scenario: Unknown event returns invalid_payload

- GIVEN a connected socket
- WHEN the client pushes `"unknown_event"` with any payload
- THEN the system MUST reply with `{:reply, {:error, %{reason: "invalid_payload"}}, socket}`

### Requirement: PlanningChannel helper functions

The system MUST verify the following helper functions:

#### Scenario: build_request_id generates correct format

- GIVEN the `build_request_id/0` function
- WHEN the function is called multiple times
- THEN each result MUST start with `"req_"` followed by an integer
- AND each result MUST be unique

#### Scenario: serialize_reason handles atoms

- GIVEN the `serialize_reason/1` function
- WHEN called with atoms like `:not_found`, `:invalid`
- THEN the function MUST return the atom as a string

#### Scenario: serialize_reason handles binaries

- GIVEN the `serialize_reason/1` function
- WHEN called with binary strings
- THEN the function MUST return the binary unchanged

#### Scenario: serialize_reason handles unknown types

- GIVEN the `serialize_reason/1` function
- WHEN called with integers, lists, or maps
- THEN the function MUST return `"invalid_payload"`

---

## Mock Configuration Requirements

### Requirement: Mox setup for all channel tests

Each channel test module MUST:

1. Import `Mox` at the top of the file
2. Set up `Mox` with `verify_on_exit!()` in the module
3. Define mocks for all external dependencies before each test using `Mox.expect/4`
4. Use `with_mock` for simple cases or `stub_with` for shared mocks

### Mock Registry by Channel

| Channel | Function to Mock | Default Return |
|---------|-----------------|----------------|
| AIChannel | `AI.stream_response/4` | `{:ok, :stream_started}` or `{:error, reason}` |
| CalendarChannel | `Calendar.toggle_favorite/3` | `{:ok, boolean}` |
| CalendarChannel | `Calendar.upsert_scheduled_meal/2` | `{:ok, %Meal{}}` |
| CalendarChannel | `Calendar.delete_scheduled_meal/3` | `:ok` or `{:error, :not_found}` |
| CalendarChannel | `Calendar.set_is_cooked/3` | `{:ok, %Meal{}}` |
| CookingChannel | `CookingService.start_session/2` | `{:ok, session_data}` |
| CookingChannel | `CookingService.session_state/2` | `{:ok, state_data}` |
| CookingChannel | `CookingService.track_step/5` | `{:ok, step_data}` |
| CookingChannel | `CookingService.finish_session/2` | `{:ok, result}` |
| CookingChannel | `CookingService.answer_question/4` | `{:ok, reply_data}` |
| PlanningChannel | `Server.start_generation/4` | `{:ok, %{run_id, request_id}}` |
| PlanningChannel | `Server.chat/3` | `{:ok, response}` |
| PlanningChannel | `Server.confirm/2` | `{:ok, result}` |
| PlanningChannel | `Server.reject/2` | `:ok` |
| PlanningChannel | `PlanningChatService.regenerate_menu/3` | `{:ok, proposal}` |
| PlanningChannel | `PlanningChatService.confirm_proposal/2` | `{:ok, result}` |
| PlanningChannel | `PlanningChatService.reject_proposal/2` | `:ok` |

---

## Acceptance Criteria

1. All 4 channel test files exist and pass (`mix test test/meal_planner_api_web/channels/`)
2. AIChannel tests: 5 test cases covering join, valid/invalid message, and error handling
3. CalendarChannel tests: 13 test cases covering authorization, all 4 events, and edge cases
4. CookingChannel tests: 15 test cases covering all events, status enums, session fallback, and unknown event
5. PlanningChannel tests: 17 test cases covering authorization, generation, chat, confirm/reject, and helpers
6. All tests use Mox for external dependency mocking
7. All tests use `async: false` to avoid DB sandbox conflicts
8. `ChannelHelpers.issue_identity_and_token/2` is shared across all channel tests
9. No skipped tests remain (remove `@tag :skip` from existing tests)

---

## Notes

- Tests should verify broadcast/push payloads match expected structure but may use pattern matching rather than exact equality
- GenServer tests in PlanningChannel may require Registry.start_link/1 in test setup
- AI stream_response mocking should simulate the streaming behavior via push events if testing streaming flow