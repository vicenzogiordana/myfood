defmodule MealPlannerApiWeb.CookingChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.{Catalog, Planning}
  alias MealPlannerApiWeb.{CookingChannel, UserSocket}

  import MealPlannerApiWeb.ChannelHelpers, only: [issue_identity_and_token: 2]

  setup do
    {:ok, user, account, token} = issue_identity_and_token("u_cook_test", "acct_cook_test")
    %{user: user, account: account, token: token}
  end

  # ==========================================================================
  # Join tests
  # ==========================================================================

  describe "join/3" do
    test "user joins cooking session room", %{account: account, user: user, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:test_session_123"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      assert socket.assigns.current_user.id == user.id
    end

    test "cross-Account join is rejected (task 3.11)" do
      user =
        user_with_memberships(
          %{email: "cook_cross@example.com"},
          [
            {%{plan: :family_4, name: "Cook Cross A"}, :owner},
            {%{plan: :individual, name: "Cook Cross B"}, :member}
          ]
        )

      membership_a = Enum.find(user.memberships, &(&1.account.name == "Cook Cross A"))
      membership_b = Enum.find(user.memberships, &(&1.account.name == "Cook Cross B"))
      token_a = issue_access_v2_token(user, membership_a)

      {:ok, socket} = connect(UserSocket, %{"token" => token_a})

      topic = "cooking:#{membership_b.account_id}:cross_session"

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, CookingChannel, topic)
    end

    test "invited (non-active) membership join is rejected (task 3.11)" do
      user =
        user_with_memberships(
          %{email: "cook_invited@example.com"},
          [
            {%{plan: :family_4, name: "Cook Invited Account"}, :owner}
          ]
        )

      [membership] = user.memberships

      {:ok, invited_membership} =
        membership
        |> MealPlannerApi.Persistence.Accounts.AccountMembership.changeset(%{status: :invited})
        |> MealPlannerApi.Repo.update()

      token = issue_access_v2_token(user, invited_membership)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{invited_membership.account_id}:invited_session"

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, CookingChannel, topic)
    end

    test "access_v1 legacy token is accepted via fallback (task 3.11)", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:legacy_session"

      assert {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      assert socket.assigns.current_membership.account_id == account.id
      assert socket.assigns.current_membership.status == :active
    end
  end

  # ==========================================================================
  # start_session tests
  # ==========================================================================

  describe "handle_in start_session" do
    test "success with valid scheduled_meal_id", %{
      account: account,
      user: user,
      token: token
    } do
      # Setup: create recipe and scheduled meal
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe for Session",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: ~D[2026-06-10],
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:test_session_456"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      _ref = push(socket, "start_session", %{"scheduled_meal_id" => meal.id})

      # start_session pushes session_started to the client
      assert_push("session_started", %{status: "active"})
    end

    test "error with missing scheduled_meal_id", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:test_session_789"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      ref = push(socket, "start_session", %{})

      assert_reply(ref, :error, %{reason: "missing_scheduled_meal_id"})
    end

    test "error with non-binary scheduled_meal_id", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:test_session_abc"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      # Non-binary triggers the else clause which returns "missing_scheduled_meal_id"
      ref = push(socket, "start_session", %{"scheduled_meal_id" => 12345})

      assert_reply(ref, :error, %{reason: "missing_scheduled_meal_id"})
    end

    test "malformed (non-UUID) scheduled_meal_id returns a clean error instead of crashing the channel",
         %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:malformed_meal_id_session"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      ref = push(socket, "start_session", %{"scheduled_meal_id" => "not-a-uuid"})

      assert_reply(ref, :error, %{reason: "invalid_meal_id"})
    end

    test "cross-Account scheduled_meal_id is rejected with meal_not_in_account (task 3.11, RED per membership-scoped-channels spec)" do
      user =
        user_with_memberships(
          %{email: "cook_meal_cross@example.com"},
          [
            {%{plan: :family_4, name: "Cook Meal Cross A"}, :owner},
            {%{plan: :individual, name: "Cook Meal Cross B"}, :member}
          ]
        )

      membership_a = Enum.find(user.memberships, &(&1.account.name == "Cook Meal Cross A"))
      membership_b = Enum.find(user.memberships, &(&1.account.name == "Cook Meal Cross B"))

      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: membership_b.account_id,
          created_by_user_id: user.id,
          name: "Recipe in Account B",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, meal_in_b} =
        Planning.schedule_meal(%{
          account_id: membership_b.account_id,
          date: ~D[2026-04-02],
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      token_a = issue_access_v2_token(user, membership_a)
      {:ok, socket} = connect(UserSocket, %{"token" => token_a})

      topic = "cooking:#{membership_a.account_id}:cross_meal_session"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      ref = push(socket, "start_session", %{"scheduled_meal_id" => meal_in_b.id})

      assert_reply(ref, :error, %{reason: "meal_not_in_account"})
    end
  end

  # ==========================================================================
  # get_state tests
  # ==========================================================================

  describe "handle_in get_state" do
    test "success with valid session_id", %{
      account: account,
      user: user,
      token: token
    } do
      # Setup: create recipe, meal, and start a session
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe for State",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:dinner]
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: ~D[2026-06-11],
          slot: :dinner,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, start_result} = MealPlannerApi.Services.CookingService.start_session(user, meal.id)
      session_id = start_result.session_id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:#{session_id}"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      ref = push(socket, "get_state", %{"session_id" => session_id})

      assert_reply(ref, :ok, %{
        session_id: ^session_id,
        status: "active"
      })
    end

    test "error with missing session_id", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:no_session"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      ref = push(socket, "get_state", %{})

      assert_reply(ref, :error, %{reason: "missing_session_id"})
    end
  end

  # ==========================================================================
  # track_step tests
  # ==========================================================================

  describe "handle_in track_step" do
    test "success with started status", %{
      account: account,
      user: user,
      token: token
    } do
      # Setup: create recipe with steps, meal, and session
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe for Track",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, step} =
        Catalog.add_recipe_step(%{
          recipe_id: recipe.id,
          step_number: 1,
          instructions: "Heat the pan",
          duration_minutes: 5
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: ~D[2026-06-12],
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, start_result} = MealPlannerApi.Services.CookingService.start_session(user, meal.id)
      session_id = start_result.session_id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:#{session_id}"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      _ref =
        push(socket, "track_step", %{
          "session_id" => session_id,
          "recipe_step_id" => step.id,
          "status" => "started"
        })

      assert_push("step_tracked", %{
        session_id: ^session_id,
        status: "started"
      })
    end

    test "success with completed status", %{
      account: account,
      user: user,
      token: token
    } do
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe Completed",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, step} =
        Catalog.add_recipe_step(%{
          recipe_id: recipe.id,
          step_number: 1,
          instructions: "Finish cooking",
          duration_minutes: 10
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: ~D[2026-06-13],
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, start_result} = MealPlannerApi.Services.CookingService.start_session(user, meal.id)
      session_id = start_result.session_id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:#{session_id}"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      _ref =
        push(socket, "track_step", %{
          "session_id" => session_id,
          "recipe_step_id" => step.id,
          "status" => "completed"
        })

      assert_push("step_tracked", %{
        status: "completed"
      })
    end

    test "success with paused status", %{
      account: account,
      user: user,
      token: token
    } do
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe Paused",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, step} =
        Catalog.add_recipe_step(%{
          recipe_id: recipe.id,
          step_number: 1,
          instructions: "Pause here",
          duration_minutes: 5
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: ~D[2026-06-14],
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, start_result} = MealPlannerApi.Services.CookingService.start_session(user, meal.id)
      session_id = start_result.session_id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:#{session_id}"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      _ref =
        push(socket, "track_step", %{
          "session_id" => session_id,
          "recipe_step_id" => step.id,
          "status" => "paused"
        })

      assert_push("step_tracked", %{
        status: "paused"
      })
    end

    test "error with missing required fields", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:missing_fields"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      # Missing session_id, recipe_step_id, and status
      ref = push(socket, "track_step", %{})

      assert_reply(ref, :error, %{reason: "missing_fields"})
    end
  end

  # ==========================================================================
  # finish_session tests
  # ==========================================================================

  describe "handle_in finish_session" do
    test "success with valid session_id", %{
      account: account,
      user: user,
      token: token
    } do
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe Finish",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:dinner]
        })

      {:ok, _ingredient} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Test Ingredient Finish",
          category: :verduras,
          calories_per_100: 50,
          protein_g_per_100: Decimal.new("2.0"),
          carbs_g_per_100: Decimal.new("5.0"),
          fat_g_per_100: Decimal.new("1.0")
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: ~D[2026-06-15],
          slot: :dinner,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, start_result} = MealPlannerApi.Services.CookingService.start_session(user, meal.id)
      session_id = start_result.session_id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:#{session_id}"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      _ref = push(socket, "finish_session", %{"session_id" => session_id})

      assert_push("session_finished", %{
        session_id: ^session_id,
        status: "completed"
      })
    end

    test "error with missing session_id", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:no_session_finish"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      ref = push(socket, "finish_session", %{})

      assert_reply(ref, :error, %{reason: "missing_session_id"})
    end
  end

  # ==========================================================================
  # ask_assistant tests
  # ==========================================================================

  describe "handle_in ask_assistant" do
    test "success with session_id in payload", %{
      account: account,
      user: user,
      token: token
    } do
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe Ask",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: ~D[2026-06-16],
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, start_result} = MealPlannerApi.Services.CookingService.start_session(user, meal.id)
      session_id = start_result.session_id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:#{session_id}"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      _ref =
        push(socket, "ask_assistant", %{
          "session_id" => session_id,
          "message" => "How long should I cook this?"
        })

      # ask_assistant pushes assistant_reply to client (noreply pattern)
      assert_push("assistant_reply", %{
        session_id: ^session_id,
        content_type: "text"
      })
    end

    test "error with missing message", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:no_msg"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      ref = push(socket, "ask_assistant", %{})

      assert_reply(ref, :error, %{reason: "missing_message"})
    end

    test "error with no active session", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      # Join without a session_id in topic
      topic = "cooking:#{account.id}:no_active_session"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      # Payload has message but no session_id and socket has no session_id
      ref =
        push(socket, "ask_assistant", %{
          "message" => "What about cooking?"
        })

      assert_reply(ref, :error, %{reason: "no_active_session"})
    end

    test "error with non-binary message", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:non_binary_msg"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      ref =
        push(socket, "ask_assistant", %{
          "message" => ["list", "message"]
        })

      assert_reply(ref, :error, %{reason: "missing_message"})
    end
  end

  # ==========================================================================
  # Unknown event test
  # ==========================================================================

  describe "handle_in unknown event" do
    test "unknown event returns event_not_implemented", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      topic = "cooking:#{account.id}:unknown_event"
      {:ok, _reply, socket} = subscribe_and_join(socket, CookingChannel, topic)

      ref = push(socket, "totally_unknown_event", %{})

      assert_reply(ref, :error, %{reason: "event_not_implemented"})
    end
  end
end
