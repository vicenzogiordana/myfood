defmodule MealPlannerApiWeb.AIChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  import MealPlannerApi.FactoryHelpers

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

    # Task 3.12 — note: AIChannel's topic is `ai_chat:<room_id>` (an opaque
    # chat/session identifier), NOT `ai:<account_id>` as the other three
    # channels use. There is no account_id embedded in the topic to
    # cross-check, so the join guard here enforces "the socket carries an
    # active membership" rather than "topic account_id == membership
    # account_id" (see apply-progress.md for the full deviation writeup).
    test "invited (non-active) membership join is rejected (task 3.12)" do
      user =
        user_with_memberships(
          %{email: "ai_invited@example.com"},
          [
            {%{plan: :family_4, name: "AI Invited Account"}, :owner}
          ]
        )

      [membership] = user.memberships

      {:ok, invited_membership} =
        membership
        |> MealPlannerApi.Persistence.Accounts.AccountMembership.changeset(%{status: :invited})
        |> MealPlannerApi.Repo.update()

      token = issue_access_v2_token(user, invited_membership)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, AIChannel, "ai_chat:invited_room")
    end

    test "access_v2 user with an :active membership joins (task 3.12)" do
      user =
        user_with_memberships(
          %{email: "ai_active@example.com"},
          [
            {%{plan: :family_4, name: "AI Active Account"}, :owner}
          ]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert {:ok, _reply, socket} =
               subscribe_and_join(socket, AIChannel, "ai_chat:active_room")

      assert socket.assigns.current_membership.status == :active
    end

    test "access_v1 legacy token is accepted via fallback (task 3.12)", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert {:ok, _reply, socket} = subscribe_and_join(socket, AIChannel, "ai_chat:legacy_room")

      assert socket.assigns.current_membership.status == :active
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
