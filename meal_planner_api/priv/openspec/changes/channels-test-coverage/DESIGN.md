# DESIGN: Phoenix Channels Test Coverage

## Metadata
- **Change ID**: channels-test-coverage
- **Author**: SDD Executor
- **Status**: design
- **Created**: 2026-06-07

## Overview

This design defines the implementation approach for writing unit/integration tests for all 4 Phoenix Channels in the MealPlannerApiWeb application. Tests will use the Phoenix.ChannelTest framework with Mox for external dependency mocking.

---

## 1. Implementation Approach

### 1.1 Mox Setup

**Current State**: Mox is **NOT** present in `mix.exs` deps.

**Action Required**: Add Mox to `dev/test` dependencies in `meal_planner_api/mix.exs`:

```elixir
defp deps do
  [
    # ... existing deps ...
    {:mox, "~> 1.1", only: :test}
  ]
end
```

After adding the dependency, run `mix deps.get`.

**Mox Configuration**: Each test module will:
1. Import `Mox` at the top
2. Call `Mox.verify_on_exit!(self())` in setup to verify all expectations are met
3. Define mock expectations before each test using `Mox.expect/4`

### 1.2 ChannelCase Customization

The existing `ChannelCase` at `test/support/channel_case.ex` provides:
- Phoenix.ChannelTest imports
- DB sandbox checkout
- SubscriptionPlanFixtures setup

**Required Enhancement**: Import `ChannelHelpers` in the `using` block:

```elixir
using do
  quote do
    import Phoenix.ChannelTest
    import MealPlannerApiWeb.ChannelHelpers  # ADD THIS
    @endpoint MealPlannerApiWeb.Endpoint
  end
end
```

### 1.3 Test Organization Per Channel

Each channel test file follows this structure:

```
defmodule MealPlannerApiWeb.XxxChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  # Mox imports and setup
  import Mox

  # Setup block with common fixtures
  setup do
    # Identity and token setup
    {:ok, user, account, token} = issue_identity_and_token(user_id, account_id)
    %{user: user, account: account, token: token}
  end

  # Describe blocks per event
  describe "join/3" do
    # Join tests
  end

  describe "handle_in event_name" do
    # Event tests
  end
end
```

### 1.4 Test Naming Conventions

Tests will follow the pattern: `test "scenario: expected behavior"` or descriptive names:

```elixir
test "authenticated user joins valid AI room"
test "join without token returns unauthenticated"
test "valid message triggers AI.stream_response"
test "missing message field returns error"
```

---

## 2. Test Structure Per Channel

### 2.1 AIChannel Test Structure (`ai_channel_test.exs`)

**File**: `test/meal_planner_api_web/channels/ai_channel_test.exs` (new)
**Estimated Lines**: ~60

```elixir
defmodule MealPlannerApiWeb.AIChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false
  import Mox

  # Mock AI behavior for tests
  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    {:ok, user, account, token} = issue_identity_and_token("u_ai", "acct_ai")
    %{user: user, account: account, token: token}
  end

  describe "join/3" do
    test "authenticated user joins valid AI room", %{user: user, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, AIChannel, "ai_chat:room_123")
      assert socket.assigns.room_id == "room_123"
    end

    test "join without token returns error", do
      {:ok, socket} = connect(UserSocket, %{})
      assert {:error, %{reason: :unauthenticated}} = subscribe_and_join(socket, AIChannel, "ai_chat:any_room")
    end
  end

  describe "handle_in new_message" do
    test "valid message triggers AI.stream_response", %{user: user, token: token} do
      # Mock AI.stream_response
      AI.Mock
      |> expect(:stream_response, fn room_id, message, u, opts ->
        assert room_id == "room_123"
        assert message == "valid text"
        assert u.id == user.id
        :ok
      end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, AIChannel, "ai_chat:room_123")

      ref = push(socket, "new_message", %{"message" => "valid text", "request_id" => "req_1", "content_type" => "text"})
      assert_reply(ref, :ok, _)
      {:noreply, _}
    end

    test "missing message field returns error", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, AIChannel, "ai_chat:room_123")

      ref = push(socket, "new_message", %{})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end

    test "non-binary message returns error", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, AIChannel, "ai_chat:room_123")

      ref = push(socket, "new_message", %{"message" => 123})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end

    test "AI.stream_response error pushes ai_response_error", %{token: token} do
      AI.Mock
      |> expect(:stream_response, fn _, _, _, _ -> {:error, "rate_limit"} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, AIChannel, "ai_chat:room_123")

      ref = push(socket, "new_message", %{"message" => "test"})
      assert_reply(ref, :error, %{reason: "ai_stream_start_failed"})
      assert_broadcast("ai_response_error", %{reason: "rate_limit"})
    end
  end
end
```

### 2.2 CalendarChannel Test Structure (`calendar_channel_test.exs`)

**File**: `test/meal_planner_api_web/channels/calendar_channel_test.exs` (new)
**Estimated Lines**: ~180

```elixir
defmodule MealPlannerApiWeb.CalendarChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false
  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "join/3 authorization" do
    test "user joins their own calendar", %{user: user, account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")
      assert socket.assigns.account_id == account.id
    end

    test "user cannot join another user's calendar", %{user: user, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      assert {:error, %{reason: "forbidden"}} = subscribe_and_join(socket, CalendarChannel, "calendar:other_account")
    end
  end

  describe "handle_in toggle_favorite" do
    test "toggle favorite success", %{account: account, user: user, token: token} do
      Calendar.Mock
      |> expect(:toggle_favorite, fn ^account.id, ^user.id, "recipe_123" -> {:ok, true} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "toggle_favorite", %{"recipe_id" => "recipe_123"})
      assert_reply(ref, :ok, %{is_favorite: true})
      assert_broadcast("favorite_toggled", %{recipe_id: "recipe_123", is_favorite: true})
    end

    test "toggle favorite with non-binary recipe_id returns error", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "toggle_favorite", %{"recipe_id" => 123})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end

    test "toggle favorite with missing recipe_id returns error", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "toggle_favorite", %{})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end

  describe "handle_in upsert_meal" do
    test "upsert meal with valid ISO 8601 date", %{account: account, user: user, token: token} do
      Calendar.Mock
      |> expect(:upsert_scheduled_meal, fn ^account.id, attrs ->
        assert attrs.date == ~D[2026-03-24]
        assert attrs.slot == :lunch
        {:ok, %{id: "meal_456", account_id: account.id, date: ~D[2026-03-24], slot: :lunch, recipe_id: "recipe_456", is_cooked: false}}
      end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "upsert_meal", %{"date" => "2026-03-24", "slot" => "lunch", "recipe_id" => "recipe_456"})
      assert_reply(ref, :ok, %{date: "2026-03-24", slot: "lunch"})
      assert_broadcast("meal_updated", %{date: "2026-03-24"})
    end

    test "upsert meal with invalid date format", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "upsert_meal", %{"date" => "invalid-date", "slot" => "lunch", "recipe_id" => "recipe_123"})
      assert_reply(ref, :error, %{reason: "invalid_date_format"})
    end

    test "upsert meal with invalid slot", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "upsert_meal", %{"date" => "2026-03-24", "slot" => "invalid", "recipe_id" => "recipe_123"})
      assert_reply(ref, :error, %{reason: "invalid_slot"})
    end
  end

  describe "handle_in delete_meal" do
    test "delete meal success", %{account: account, token: token} do
      Calendar.Mock
      |> expect(:delete_scheduled_meal, fn ^account.id, ~D[2026-03-24], :lunch -> :ok end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "delete_meal", %{"date" => "2026-03-24", "slot" => "lunch"})
      assert_reply(ref, :ok, %{date: "2026-03-24", slot: "lunch"})
      assert_broadcast("meal_deleted", %{date: "2026-03-24", slot: "lunch"})
    end

    test "delete meal not found", %{account: account, token: token} do
      Calendar.Mock
      |> expect(:delete_scheduled_meal, fn _, _, _ -> {:error, :not_found} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "delete_meal", %{"date" => "2026-03-24", "slot" => "lunch"})
      assert_reply(ref, :error, %{reason: "not_found"})
    end
  end

  describe "handle_in set_is_cooked" do
    test "set is_cooked with boolean true", %{account: account, token: token} do
      Calendar.Mock
      |> expect(:set_is_cooked, fn ^account.id, "meal_789", true -> {:ok, %{id: "meal_789", is_cooked: true}} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "set_is_cooked", %{"meal_id" => "meal_789", "is_cooked" => true})
      assert_reply(ref, :ok, %{meal_id: "meal_789", is_cooked: true})
      assert_broadcast("meal_cooked_state_changed", %{meal_id: "meal_789", is_cooked: true})
    end

    test "set is_cooked with non-boolean value", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "set_is_cooked", %{"meal_id" => "meal_789", "is_cooked" => "yes"})
      assert_reply(ref, :error, %{reason: "invalid_is_cooked"})
    end

    test "set is_cooked with missing meal_id", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "set_is_cooked", %{"is_cooked" => true})
      assert_reply(ref, :error, %{reason: "missing_params"})
    end
  end

  describe "handle_in unknown event" do
    test "unknown event returns invalid_payload", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "unknown_event", %{})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end
end
```

### 2.3 CookingChannel Test Structure (`cooking_channel_test.exs`)

**File**: `test/meal_planner_api_web/channels/cooking_channel_test.exs` (expand existing)
**Estimated Lines**: ~200

**Note**: Remove `@tag :skip` from existing tests. The existing skeleton test will be replaced with proper Mox-based tests.

```elixir
defmodule MealPlannerApiWeb.CookingChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false
  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    {:ok, user, account, token} = issue_identity_and_token("u_cooking", "acct_cooking")
    %{user: user, account: account, token: token}
  end

  describe "join/3" do
    test "authenticated user joins cooking session", %{token: token, account: account} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:session_123")
      # CookingChannel doesn't set any assigns on join
      refute Map.has_key?(socket.assigns, :account_id)
    end
  end

  describe "handle_in start_session" do
    test "start session with valid meal_id", %{user: user, token: token, account: account} do
      CookingService.Mock
      |> expect(:start_session, fn ^user, "meal_123" ->
        {:ok, %{session_id: "sess_123", steps: []}}
      end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "start_session", %{"scheduled_meal_id" => "meal_123"})
      assert_reply(ref, :ok, %{session_id: "sess_123"})
      assert_broadcast("session_started", %{session_id: "sess_123"})
    end

    test "start session with missing meal_id", %{token: token, account: account} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "start_session", %{})
      assert_reply(ref, :error, %{reason: "missing_scheduled_meal_id"})
    end

    test "start session with non-binary meal_id", %{token: token, account: account} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "start_session", %{"scheduled_meal_id" => 123})
      assert_reply(ref, :error, %{reason: "missing_scheduled_meal_id"})
    end
  end

  describe "handle_in get_state" do
    test "get state with valid session_id", %{user: user, token: token, account: account} do
      CookingService.Mock
      |> expect(:session_state, fn ^user, "sess_123" ->
        {:ok, %{session_id: "sess_123", status: :active}}
      end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "get_state", %{"session_id" => "sess_123"})
      assert_reply(ref, :ok, %{session_id: "sess_123", status: :active})
    end

    test "get state with missing session_id", %{token: token, account: account} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "get_state", %{})
      assert_reply(ref, :error, %{reason: "missing_session_id"})
    end
  end

  describe "handle_in track_step" do
    test "track step with all required fields", %{user: user, token: token, account: account} do
      CookingService.Mock
      |> expect(:track_step, fn ^user, "sess_123", "step_456", :started, %{"extra_field" => "passed_through"} ->
        {:ok, %{step_id: "step_456", status: :started}}
      end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "track_step", %{
        "session_id" => "sess_123",
        "recipe_step_id" => "step_456",
        "status" => "started",
        "extra_field" => "passed_through"
      })
      assert_reply(ref, :ok, _)
      assert_broadcast("step_tracked", %{step_id: "step_456"})
    end

    test "track step with all status enum values", %{user: user, token: token, account: account} do
      CookingService.Mock
      |> expect(:track_step, fn ^user, "sess_123", "step_456", :paused, _ -> {:ok, %{}} end)
      |> expect(:track_step, fn ^user, "sess_123", "step_456", :completed, _ -> {:ok, %{}} end)
      |> expect(:track_step, fn ^user, "sess_123", "step_456", :error, _ -> {:ok, %{}} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      for status <- ["paused", "completed", "error"] do
        ref = push(socket, "track_step", %{"session_id" => "sess_123", "recipe_step_id" => "step_456", "status" => status})
        assert_reply(ref, :ok, _)
      end
    end

    test "track step with missing required fields", %{token: token, account: account} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "track_step", %{"session_id" => "sess_123"})
      assert_reply(ref, :error, %{reason: "missing_fields"})
    end
  end

  describe "handle_in finish_session" do
    test "finish session success", %{user: user, token: token, account: account} do
      CookingService.Mock
      |> expect(:finish_session, fn ^user, "sess_123" -> {:ok, %{session_id: "sess_123"}} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "finish_session", %{"session_id" => "sess_123"})
      assert_reply(ref, :ok, %{session_id: "sess_123"})
      assert_broadcast("session_finished", %{session_id: "sess_123"})
    end

    test "finish session with missing session_id", %{token: token, account: account} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "finish_session", %{})
      assert_reply(ref, :error, %{reason: "missing_session_id"})
    end
  end

  describe "handle_in ask_assistant" do
    test "ask assistant with explicit session_id", %{user: user, token: token, account: account} do
      CookingService.Mock
      |> expect(:answer_question, fn ^user, "sess_123", "How do I know when sauce is ready?", "text" ->
        {:ok, %{reply: "cooking tip"}}
      end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "ask_assistant", %{
        "request_id" => "req_1",
        "message" => "How do I know when sauce is ready?",
        "content_type" => "text",
        "session_id" => "sess_123"
      })
      assert_reply(ref, :ok, _)
      assert_broadcast("assistant_reply", %{reply: "cooking tip"})
    end

    test "ask assistant with socket session_id fallback", %{user: user, token: token, account: account} do
      CookingService.Mock
      |> expect(:answer_question, fn ^user, "sess_from_socket", "Next step?", "text" -> {:ok, %{}} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_from_socket")

      ref = push(socket, "ask_assistant", %{
        "request_id" => "req_2",
        "message" => "Next step?",
        "content_type" => "text"
      })
      assert_reply(ref, :ok, _)
    end

    test "ask assistant with no session_id available", %{token: token, account: account} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "ask_assistant", %{"message" => "hello", "request_id" => "req_3"})
      assert_reply(ref, :error, %{reason: "no_active_session"})
    end

    test "ask assistant with non-binary message", %{token: token, account: account} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "ask_assistant", %{"message" => 123, "request_id" => "req_4"})
      assert_reply(ref, :error, %{reason: "missing_message"})
    end
  end

  describe "handle_in unknown event" do
    test "unknown event returns event_not_implemented", %{token: token, account: account} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, "cooking:#{account.id}:sess_123")

      ref = push(socket, "unknown_event", %{})
      assert_reply(ref, :error, %{reason: "event_not_implemented"})
    end
  end
end
```

### 2.4 PlanningChannel Test Structure (`planning_channel_test.exs`)

**File**: `test/meal_planner_api_web/channels/planning_channel_test.exs` (expand existing)
**Estimated Lines**: ~220

**Note**: Replace the existing skeleton test file. PlanningChannel requires GenServer/Registry setup for some tests.

```elixir
defmodule MealPlannerApiWeb.PlanningChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false
  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    {:ok, user, account, token} = issue_identity_and_token("u_planning", "acct_planning")
    %{user: user, account: account, token: token}
  end

  describe "join/3 authorization" do
    test "user joins their own planning channel", %{user: user, account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")
      assert socket.assigns.account_id == account.id
    end

    test "user cannot join another user's planning channel", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      assert {:error, %{reason: "forbidden"}} = subscribe_and_join(socket, PlanningChannel, "planning:other_account")
    end
  end

  describe "handle_in generate_menu" do
    test "generate menu success", %{user: user, account: account, token: token} do
      Server.Mock
      |> expect(:start_generation, fn ^account.id, ^user.id, constraints, socket_pid when is_pid(socket_pid) ->
        {:ok, "run_123"}
      end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "generate_menu", %{"constraints" => %{}})
      assert_reply(ref, :ok, %{request_id: request_id, run_id: "run_123"})
      assert_broadcast("generation_started", %{run_id: "run_123"})
    end

    test "generate menu when already running", %{account: account, token: token} do
      Server.Mock
      |> expect(:start_generation, fn _, _, _, _ -> {:error, :already_running} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "generate_menu", %{})
      assert_reply(ref, :error, %{reason: "generation_in_progress"})
    end

    test "generate menu when server returns other error", %{account: account, token: token} do
      Server.Mock
      |> expect(:start_generation, fn _, _, _, _ -> {:error, :timeout} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "generate_menu", %{})
      assert_reply(ref, :error, %{reason: "timeout"})
      assert_broadcast("generation_error", %{reason: "timeout"})
    end
  end

  describe "handle_in swap_constraints" do
    test "swap constraints success", %{user: user, account: account, token: token} do
      PlanningChatService.Mock
      |> expect(:regenerate_menu, fn ^user, base_payload, constraints ->
        assert constraints == %{"dietary" => "vegetarian"}
        {:ok, %{run: %{id: "run_swap"}, proposal: %{id: "prop_swap_1"}, proposal_json: %{}}}
      end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "swap_constraints", %{
        "constraints" => %{"dietary" => "vegetarian"},
        "base_payload" => %{"date_range" => "2026-03-24..2026-03-28"},
        "request_id" => "req_swap_1"
      })
      assert_reply(ref, :ok, %{proposal_id: "prop_swap_1"})
      assert_broadcast("proposal_ready", %{proposal_id: "prop_swap_1"})
    end

    test "swap constraints failure", %{user: user, account: account, token: token} do
      PlanningChatService.Mock
      |> expect(:regenerate_menu, fn _, _, _ -> {:error, :invalid_constraints} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "swap_constraints", %{"constraints" => %{"invalid" => "value"}, "request_id" => "req_swap_err"})
      assert_broadcast("generation_error", %{reason: "invalid_constraints"})
    end
  end

  describe "handle_in chat" do
    test "chat when GenServer exists", %{user: user, account: account, token: token} do
      # Simulate GenServer running by registering a mock
      pid = self()
      Registry.put_meta(MealPlannerApi.Generation.Generations, {:generation, account.id}, %{pid: pid})

      Server.Mock
      |> expect(:chat, fn ^pid, "prop_123", "Can I swap pasta for rice?" -> :ok end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "chat", %{
        "message" => "Can I swap pasta for rice?",
        "proposal_id" => "prop_123",
        "request_id" => "req_chat_1"
      })
      # chat returns :noreply when GenServer handles it
      assert ref.__struct__ == Phoenix.Socket.Broadcast
    after
      Registry.unregister(MealPlannerApi.Generation.Generations, {:generation, account.id})
    end

    test "chat when no GenServer exists", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "chat", %{"message" => "hello", "request_id" => "req_chat_2"})
      assert_reply(ref, :error, %{reason: "no_active_generation"})
    end

    test "chat with non-binary message", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "chat", %{"message" => 123})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end

  describe "handle_in confirm_proposal" do
    test "confirm via GenServer", %{user: user, account: account, token: token} do
      pid = self()
      Registry.put_meta(MealPlannerApi.Generation.Generations, {:generation, account.id}, %{pid: pid})

      Server.Mock
      |> expect(:confirm, fn ^pid, "prop_123" -> {:ok, %{confirmed: true}} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "confirm_proposal", %{"proposal_id" => "prop_123"})
      assert_reply(ref, :ok, %{confirmed: true})
    after
      Registry.unregister(MealPlannerApi.Generation.Generations, {:generation, account.id})
    end

    test "confirm via fallback service", %{user: user, account: account, token: token} do
      PlanningChatService.Mock
      |> expect(:confirm_proposal, fn ^user, "prop_456" -> {:ok, %{confirmed: true}} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "confirm_proposal", %{"proposal_id" => "prop_456"})
      assert_reply(ref, :ok, %{confirmed: true, status: "confirmed"})
      assert_broadcast("proposal_confirmed", %{status: "confirmed"})
    end

    test "confirm via fallback service failure", %{user: user, account: account, token: token} do
      PlanningChatService.Mock
      |> expect(:confirm_proposal, fn ^user, "invalid" -> {:error, :not_found} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "confirm_proposal", %{"proposal_id" => "invalid"})
      assert_reply(ref, :error, %{reason: "not_found"})
    end
  end

  describe "handle_in reject_proposal" do
    test "reject via GenServer", %{user: user, account: account, token: token} do
      pid = self()
      Registry.put_meta(MealPlannerApi.Generation.Generations, {:generation, account.id}, %{pid: pid})

      Server.Mock
      |> expect(:reject, fn ^pid, "prop_123" -> :ok end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "reject_proposal", %{"proposal_id" => "prop_123"})
      assert ref.__struct__ == Phoenix.Socket.Broadcast
    after
      Registry.unregister(MealPlannerApi.Generation.Generations, {:generation, account.id})
    end

    test "reject via fallback service", %{user: user, account: account, token: token} do
      PlanningChatService.Mock
      |> expect(:reject_proposal, fn ^user, "prop_456" -> {:ok, %{}} end)

      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "reject_proposal", %{"proposal_id" => "prop_456"})
      assert_reply(ref, :ok, %{status: "rejected"})
      assert_broadcast("proposal_rejected", %{status: "rejected"})
    end
  end

  describe "handle_in unknown event" do
    test "unknown event returns invalid_payload", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "unknown_event", %{})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end

  describe "helper functions" do
    test "build_request_id generates correct format" do
      request_id = PlanningChannel.build_request_id()
      assert String.starts_with?(request_id, "req_")
      assert String.to_integer(String.replace(request_id, "req_", "")) > 0
    end

    test "build_request_id generates unique ids" do
      ids = for _ <- 1..100, do: PlanningChannel.build_request_id()
      assert ids == Enum.uniq(ids)
    end

    test "serialize_reason handles atoms" do
      assert PlanningChannel.serialize_reason(:not_found) == "not_found"
      assert PlanningChannel.serialize_reason(:invalid) == "invalid"
    end

    test "serialize_reason handles binaries" do
      assert PlanningChannel.serialize_reason("already_exists") == "already_exists"
    end

    test "serialize_reason handles unknown types" do
      assert PlanningChannel.serialize_reason(123) == "invalid_payload"
      assert PlanningChannel.serialize_reason([1, 2]) == "invalid_payload"
      assert PlanningChannel.serialize_reason(%{key: "value"}) == "invalid_payload"
    end
  end
end
```

---

## 3. Shared Utilities: ChannelHelpers Module

**File**: `test/support/channel_helpers.ex` (new)
**Estimated Lines**: ~30

```elixir
defmodule MealPlannerApiWeb.ChannelHelpers do
  @moduledoc """
  Shared helpers for channel tests.
  """

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian

  @doc """
  Creates or retrieves an identity and generates a valid JWT access token.

  ## Returns

      {:ok, user, account, token}

  ## Examples

      {:ok, user, account, token} = issue_identity_and_token("user_1", "account_1")
  """
  @spec issue_identity_and_token(String.t(), String.t()) :: {:ok, map(), map(), String.t()}
  def issue_identity_and_token(user_id, account_id) do
    with {:ok, %{user: user, account: account}} <-
           Accounts.find_or_create_identity(%{"user_id" => user_id, "account_id" => account_id}),
         {:ok, token, _claims} <-
           Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
             token_type: "access"
           ) do
      {:ok, user, account, token}
    end
  end
end
```

---

## 4. Mox Mock Definitions

Create mock modules for external dependencies. These need to be defined in `test/support/mocks/` directory.

### 4.1 AI Mock

**File**: `test/support/mocks/ai_mock.ex` (new)

```elixir
defmodule MealPlannerApi.AI.Mock do
  use Mox

  def mock_stream_response_ok do
    expect(AI.Mock, :stream_response, fn _, _, _, _ -> :ok end)
  end

  def mock_stream_response_error(reason) do
    expect(AI.Mock, :stream_response, fn _, _, _, _ -> {:error, reason} end)
  end
end
```

### 4.2 Calendar Mock

**File**: `test/support/mocks/calendar_mock.ex` (new)

```elixir
defmodule MealPlannerApi.Persistence.Calendar.Mock do
  use Mox

  def mock_toggle_favorite(is_favorite) do
    expect(Calendar.Mock, :toggle_favorite, fn _, _, _ -> {:ok, is_favorite} end)
  end

  def mock_upsert_scheduled_meal(meal) do
    expect(Calendar.Mock, :upsert_scheduled_meal, fn _, _ -> {:ok, meal} end)
  end

  def mock_delete_scheduled_meal(result) do
    expect(Calendar.Mock, :delete_scheduled_meal, fn _, _, _ -> result end)
  end

  def mock_set_is_cooked(meal) do
    expect(Calendar.Mock, :set_is_cooked, fn _, _, _ -> {:ok, meal} end)
  end
end
```

### 4.3 CookingService Mock

**File**: `test/support/mocks/cooking_service_mock.ex` (new)

```elixir
defmodule MealPlannerApi.Services.CookingService.Mock do
  use Mox

  def mock_start_session(session_data) do
    expect(CookingService.Mock, :start_session, fn _, _ -> {:ok, session_data} end)
  end

  def mock_session_state(state_data) do
    expect(CookingService.Mock, :session_state, fn _, _ -> {:ok, state_data} end)
  end

  def mock_track_step(result) do
    expect(CookingService.Mock, :track_step, fn _, _, _, _, _ -> {:ok, result} end)
  end

  def mock_finish_session(result) do
    expect(CookingService.Mock, :finish_session, fn _, _ -> {:ok, result} end)
  end

  def mock_answer_question(result) do
    expect(CookingService.Mock, :answer_question, fn _, _, _, _ -> {:ok, result} end)
  end
end
```

### 4.4 Server Mock

**File**: `test/support/mocks/server_mock.ex` (new)

```elixir
defmodule MealPlannerApi.Generation.Server.Mock do
  use Mox

  def mock_start_generation(result) do
    expect(Server.Mock, :start_generation, fn _, _, _, _ -> result end)
  end

  def mock_chat do
    expect(Server.Mock, :chat, fn _, _, _ -> :ok end)
  end

  def mock_confirm(result) do
    expect(Server.Mock, :confirm, fn _, _ -> result end)
  end

  def mock_reject do
    expect(Server.Mock, :reject, fn _, _ -> :ok end)
  end
end
```

### 4.5 PlanningChatService Mock

**File**: `test/support/mocks/planning_chat_service_mock.ex` (new)

```elixir
defmodule MealPlannerApi.Services.PlanningChatService.Mock do
  use Mox

  def mock_regenerate_menu(result) do
    expect(PlanningChatService.Mock, :regenerate_menu, fn _, _, _ -> result end)
  end

  def mock_confirm_proposal(result) do
    expect(PlanningChatService.Mock, :confirm_proposal, fn _, _ -> result end)
  end

  def mock_reject_proposal(result) do
    expect(PlanningChatService.Mock, :reject_proposal, fn _, _ -> result end)
  end
end
```

---

## 5. Mock Configuration Requirements

### 5.1 Mox Setup in TestHelper

Add Mox setup to `test/test_helper.exs`:

```elixir
# Add after ExUnit.start
Mox.definitions(MealPlannerApi.AI.Mock)
Mox.definitions(MealPlannerApi.Persistence.Calendar.Mock)
Mox.definitions(MealPlannerApi.Services.CookingService.Mock)
Mox.definitions(MealPlannerApi.Generation.Server.Mock)
Mox.definitions(MealPlannerApi.Services.PlanningChatService.Mock)
```

### 5.2 Mock Registry by Channel

| Channel | Module | Function to Mock | Default Return |
|---------|--------|-----------------|----------------|
| AIChannel | `MealPlannerApi.AI` | `stream_response/4` | `:ok` or `{:error, reason}` |
| CalendarChannel | `MealPlannerApi.Persistence.Calendar` | `toggle_favorite/3` | `{:ok, boolean}` |
| CalendarChannel | `MealPlannerApi.Persistence.Calendar` | `upsert_scheduled_meal/2` | `{:ok, %Meal{}}` |
| CalendarChannel | `MealPlannerApi.Persistence.Calendar` | `delete_scheduled_meal/3` | `:ok` or `{:error, :not_found}` |
| CalendarChannel | `MealPlannerApi.Persistence.Calendar` | `set_is_cooked/3` | `{:ok, %Meal{}}` |
| CookingChannel | `MealPlannerApi.Services.CookingService` | `start_session/2` | `{:ok, session_data}` |
| CookingChannel | `MealPlannerApi.Services.CookingService` | `session_state/2` | `{:ok, state_data}` |
| CookingChannel | `MealPlannerApi.Services.CookingService` | `track_step/5` | `{:ok, step_data}` |
| CookingChannel | `MealPlannerApi.Services.CookingService` | `finish_session/2` | `{:ok, result}` |
| CookingChannel | `MealPlannerApi.Services.CookingService` | `answer_question/4` | `{:ok, reply_data}` |
| PlanningChannel | `MealPlannerApi.Generation.Server` | `start_generation/4` | `{:ok, run_id}` |
| PlanningChannel | `MealPlannerApi.Generation.Server` | `chat/3` | `:ok` |
| PlanningChannel | `MealPlannerApi.Generation.Server` | `confirm/2` | `{:ok, result}` |
| PlanningChannel | `MealPlannerApi.Generation.Server` | `reject/2` | `:ok` |
| PlanningChannel | `MealPlannerApi.Services.PlanningChatService` | `regenerate_menu/3` | `{:ok, proposal}` |
| PlanningChannel | `MealPlannerApi.Services.PlanningChatService` | `confirm_proposal/2` | `{:ok, result}` |
| PlanningChannel | `MealPlannerApi.Services.PlanningChatService` | `reject_proposal/2` | `:ok` |

---

## 6. Estimated Lines Per Test File

| File | Estimated Lines | Notes |
|------|----------------|-------|
| `ai_channel_test.exs` | ~60 | 5 test cases |
| `calendar_channel_test.exs` | ~180 | 13 test cases |
| `cooking_channel_test.exs` | ~200 | 15 test cases (expand existing) |
| `planning_channel_test.exs` | ~220 | 17 test cases (replace skeleton) |
| `channel_helpers.exs` | ~30 | Shared helper |
| **Total** | **~690** | |

---

## 7. Dependencies and Risks

### 7.1 Dependencies

1. **Mox**: Not currently in `mix.exs` - must be added
2. **Phoenix.ChannelTest**: Already available via Phoenix
3. **Registry**: Already running in test environment
4. **Guardian**: Used for token generation in tests

### 7.2 Risks

| Risk | Mitigation |
|------|------------|
| Mox not in deps | Add `{:mox, "~> 1.1", only: :test}` to mix.exs |
| Sandbox conflicts | All tests use `async: false` |
| GenServer not running for Registry tests | Set up Registry entries in setup block, clean up in `after` block |
| Mock functions taking user struct vs user_id | Use `^user` pin operator for exact match |
| Token expiration | Tests create fresh tokens, no expiration concern |
| Multiple mock expectations | Use `expect/4` with `count: n` for repeated calls |

### 7.3 Edge Cases in Mocking

1. **GenServer PID matching**: Server.start_generation receives `socket.channel_pid`. Use `when is_pid(socket_pid)` guard in mock expectations.

2. **Registry cleanup**: Tests that register GenServer entries must use `after` blocks to clean up.

3. **Pin operator usage**: Always pin user/account variables in mock expectations:
   ```elixir
   expect(:mock, :func, fn ^user.id, ^account.id, _ -> :ok end)
   ```

4. **Broadcast pattern matching**: Use `assert_broadcast` with pattern matching rather than exact equality:
   ```elixir
   assert_broadcast("event_name", %{field: _})
   ```

---

## 8. Acceptance Criteria Checklist

- [ ] Mox added to `mix.exs` deps
- [ ] `ChannelHelpers.issue_identity_and_token/2` created
- [ ] `ChannelCase` updated to import `ChannelHelpers`
- [ ] Mox definitions added to `test_helper.exs`
- [ ] `ai_channel_test.exs` created with 5 tests
- [ ] `calendar_channel_test.exs` created with 13 tests
- [ ] `cooking_channel_test.exs` expanded with 15 tests (remove `@tag :skip`)
- [ ] `planning_channel_test.exs` expanded with 17 tests (replace skeleton)
- [ ] All tests pass: `mix test test/meal_planner_api_web/channels/`
- [ ] All tests use `async: false`
- [ ] All external dependencies mocked with Mox

---

## 9. File Changes Summary

### New Files
- `test/meal_planner_api_web/channels/ai_channel_test.exs`
- `test/meal_planner_api_web/channels/calendar_channel_test.exs`
- `test/support/channel_helpers.ex`
- `test/support/mocks/ai_mock.ex`
- `test/support/mocks/calendar_mock.ex`
- `test/support/mocks/cooking_service_mock.ex`
- `test/support/mocks/server_mock.ex`
- `test/support/mocks/planning_chat_service_mock.ex`

### Modified Files
- `meal_planner_api/mix.exs` - Add Mox dependency
- `test/support/channel_case.ex` - Import ChannelHelpers
- `test/test_helper.exs` - Add Mox definitions
- `test/meal_planner_api_web/channels/cooking_channel_test.exs` - Expand with Mox tests
- `test/meal_planner_api_web/channels/planning_channel_test.exs` - Replace skeleton with Mox tests

---

## 10. Implementation Order

1. Add Mox to `mix.exs` and run `mix deps.get`
2. Create `test/support/channel_helpers.ex`
3. Update `test/support/channel_case.ex` to import ChannelHelpers
4. Update `test/test_helper.exs` with Mox definitions
5. Create Mox mock modules in `test/support/mocks/`
6. Create `ai_channel_test.exs`
7. Create `calendar_channel_test.exs`
8. Expand `cooking_channel_test.exs` (remove `@tag :skip`)
9. Expand `planning_channel_test.exs` (replace skeleton)
10. Run `mix test test/meal_planner_api_web/channels/` and fix any failures