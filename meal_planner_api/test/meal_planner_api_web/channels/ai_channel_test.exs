defmodule MealPlannerApiWeb.AIChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  alias MealPlannerApiWeb.{AIChannel, UserSocket}

  setup do
    {:ok, _user, _account, token} = issue_identity_and_token("u_ai_test", "acct_ai_test")
    %{token: token}
  end

  describe "join/3" do
    test "authenticated user joins valid AI room", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, AIChannel, "ai_chat:room_123")

      assert socket.assigns.room_id == "room_123"
    end

    test "join without token returns error" do
      # When no token is provided, connect returns :error
      assert :error = connect(UserSocket, %{})
    end
  end

  describe "handle_in new_message" do
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

    test "non-binary message (list) returns error", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, AIChannel, "ai_chat:room_123")

      ref = push(socket, "new_message", %{"message" => ["a", "list"]})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end
end
