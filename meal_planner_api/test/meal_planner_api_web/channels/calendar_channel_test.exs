defmodule MealPlannerApiWeb.CalendarChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  alias MealPlannerApi.{Persistence.Calendar, Persistence.Catalog, Persistence.Planning}
  alias MealPlannerApiWeb.{CalendarChannel, UserSocket}

  setup do
    {:ok, user, account, token} = issue_identity_and_token("u_cal_test", "acct_cal_test")
    %{user: user, account: account, token: token}
  end

  describe "join/3 authorization" do
    test "user joins their own calendar", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      assert socket.assigns.account_id == account.id
    end

    test "user cannot join another user's calendar", %{token: token} do
      # Try to join a different account's calendar
      # The socket is authenticated but the account_id doesn't match
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, CalendarChannel, "calendar:other_account_id")
    end
  end

  describe "handle_in toggle_favorite" do
    test "toggle favorite success", %{account: account, user: user, token: token} do
      # Create a recipe first
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe for Favorite",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      recipe_id = recipe.id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "toggle_favorite", %{"recipe_id" => recipe_id})
      assert_reply(ref, :ok, %{is_favorite: true, recipe_id: ^recipe_id})
      assert_broadcast("favorite_toggled", %{recipe_id: ^recipe_id, is_favorite: true})
    end

    test "toggle favorite with non-binary recipe_id returns error", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "toggle_favorite", %{"recipe_id" => 123})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end

    test "toggle favorite with missing recipe_id returns error", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "toggle_favorite", %{})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end

  describe "handle_in upsert_meal" do
    test "upsert meal with valid ISO8601 date", %{account: account, user: user, token: token} do
      # Create a recipe first
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe for Upsert",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      recipe_id = recipe.id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref =
        push(socket, "upsert_meal", %{
          "date" => "2026-03-24",
          "slot" => "lunch",
          "recipe_id" => recipe_id
        })

      assert_reply(ref, :ok, %{date: "2026-03-24", slot: "lunch"})
      assert_broadcast("meal_updated", %{date: "2026-03-24"})
    end

    test "upsert meal with invalid date format", %{account: account, user: user, token: token} do
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe for Invalid Date",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      recipe_id = recipe.id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref =
        push(socket, "upsert_meal", %{
          "date" => "invalid-date",
          "slot" => "lunch",
          "recipe_id" => recipe_id
        })

      assert_reply(ref, :error, %{reason: "invalid_date_format"})
    end

    test "upsert meal with invalid slot", %{account: account, user: user, token: token} do
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe for Invalid Slot",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      recipe_id = recipe.id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref =
        push(socket, "upsert_meal", %{
          "date" => "2026-03-24",
          "slot" => "invalid",
          "recipe_id" => recipe_id
        })

      assert_reply(ref, :error, %{reason: "invalid_slot"})
    end
  end

  describe "handle_in delete_meal" do
    test "delete meal success", %{account: account, user: user, token: token} do
      # Create a recipe and meal first
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe for Delete",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, _meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: ~D[2026-03-25],
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "delete_meal", %{"date" => "2026-03-25", "slot" => "lunch"})
      assert_reply(ref, :ok, %{date: "2026-03-25", slot: "lunch"})
      assert_broadcast("meal_deleted", %{date: "2026-03-25", slot: "lunch"})
    end

    test "delete meal not found", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "delete_meal", %{"date" => "2099-03-25", "slot" => "lunch"})
      assert_reply(ref, :error, %{reason: "not_found"})
    end
  end

  describe "handle_in set_is_cooked" do
    test "set is_cooked with boolean true", %{account: account, user: user, token: token} do
      # Create a recipe and meal first
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe for Cook",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: ~D[2026-03-26],
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      meal_id = meal.id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "set_is_cooked", %{"meal_id" => meal_id, "is_cooked" => true})
      assert_reply(ref, :ok, %{meal_id: ^meal_id, is_cooked: true})
      assert_broadcast("meal_cooked_state_changed", %{meal_id: ^meal_id, is_cooked: true})
    end

    test "set is_cooked with non-boolean value", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "set_is_cooked", %{"meal_id" => "meal_789", "is_cooked" => "yes"})
      assert_reply(ref, :error, %{reason: "invalid_is_cooked"})
    end

    test "set is_cooked with missing meal_id", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "set_is_cooked", %{"is_cooked" => true})
      assert_reply(ref, :error, %{reason: "missing_params"})
    end
  end

  describe "handle_in unknown event" do
    test "unknown event returns invalid_payload", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CalendarChannel, "calendar:#{account.id}")

      ref = push(socket, "unknown_event", %{})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end
end
