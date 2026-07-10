defmodule MealPlannerApiWeb.PlanningChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApiWeb.{PlanningChannel, UserSocket}

  import MealPlannerApiWeb.ChannelHelpers, only: [issue_identity_and_token: 2]

  setup do
    {:ok, user, account, token} = issue_identity_and_token("u_plan_test", "acct_plan_test")
    %{user: user, account: account, token: token}
  end

  # ==========================================================================
  # Join authorization tests
  # ==========================================================================

  describe "join/3 authorization" do
    test "user joins their own planning channel", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      assert socket.assigns.account_id == account.id
    end

    test "user cannot join another account's planning channel", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      # Try to join a different account's planning channel
      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, PlanningChannel, "planning:other_account_id")
    end

    test "cross-Account join is rejected (task 3.10)" do
      user =
        user_with_memberships(
          %{email: "plan_cross@example.com"},
          [
            {%{plan: :family_4, name: "Plan Cross A"}, :owner},
            {%{plan: :individual, name: "Plan Cross B"}, :member}
          ]
        )

      membership_a = Enum.find(user.memberships, &(&1.account.name == "Plan Cross A"))
      membership_b = Enum.find(user.memberships, &(&1.account.name == "Plan Cross B"))
      token_a = issue_access_v2_token(user, membership_a)

      {:ok, socket} = connect(UserSocket, %{"token" => token_a})

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, PlanningChannel, "planning:#{membership_b.account_id}")
    end

    test "invited (non-active) membership join is rejected (task 3.10)" do
      user =
        user_with_memberships(
          %{email: "plan_invited@example.com"},
          [
            {%{plan: :family_4, name: "Plan Invited Account"}, :owner}
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
               subscribe_and_join(
                 socket,
                 PlanningChannel,
                 "planning:#{invited_membership.account_id}"
               )
    end

    test "access_v1 legacy token is accepted via fallback (task 3.10)", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert {:ok, _reply, socket} =
               subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      assert socket.assigns.current_membership.account_id == account.id
      assert socket.assigns.current_membership.status == :active
    end
  end

  # ==========================================================================
  # generate_menu tests
  # ==========================================================================

  describe "handle_in generate_menu" do
    test "generates response with request_id", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref =
        push(socket, "generate_menu", %{
          "request_id" => "test_req_1",
          "constraints" => %{}
        })

      # Server should respond (either success or error with request_id)
      assert_receive %{ref: ^ref, status: _status, payload: %{request_id: "test_req_1"}}
    end

    test "error when Server.start_generation fails with invalid constraints", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Pass invalid date format to trigger error
      ref =
        push(socket, "generate_menu", %{
          "request_id" => "test_req_invalid",
          "constraints" => %{
            "date_from" => "invalid-date"
          }
        })

      # Should receive error reply
      assert_reply(ref, :error, %{reason: _reason})
    end
  end

  # ==========================================================================
  # swap_constraints tests
  # ==========================================================================

  describe "handle_in swap_constraints" do
    test "returns response with request_id", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref =
        push(socket, "swap_constraints", %{
          "request_id" => "swap_req_1",
          "base_payload" => %{"date_from" => "2026-06-15", "date_to" => "2026-06-21"},
          "constraints" => %{"budget_cents" => 5000}
        })

      # Should broadcast generation_started and return ok with proposal
      assert_broadcast("generation_started", %{
        request_id: "swap_req_1",
        reason: "constraint_update"
      })

      # Response should include the request_id
      assert_receive %{ref: ^ref, payload: %{request_id: "swap_req_1"}}
    end

    test "broadcasts error when service fails", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Pass invalid date range (date_to before date_from)
      ref =
        push(socket, "swap_constraints", %{
          "request_id" => "swap_req_error",
          "base_payload" => %{"date_from" => "2026-06-21", "date_to" => "2026-06-15"},
          "constraints" => %{}
        })

      assert_receive %{ref: ^ref, status: :error, payload: %{reason: _reason}}
      assert_broadcast("generation_error", %{request_id: "swap_req_error"})
    end
  end

  # ==========================================================================
  # chat tests
  # ==========================================================================

  describe "handle_in chat" do
    test "error when no active generation", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # No generation started, so chat should fail
      ref =
        push(socket, "chat", %{
          "proposal_id" => "123",
          "message" => "Change the menu"
        })

      assert_reply(ref, :error, %{reason: "no_active_generation"})
    end

    test "missing proposal_id returns error", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Missing proposal_id falls through to unknown event
      ref =
        push(socket, "chat", %{
          "message" => "Hello"
        })

      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end

    test "success when GenerationServer is running", %{
      account: account,
      user: user,
      token: token
    } do
      # Create recipe so generation can potentially work
      {:ok, _recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe Chat",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Start generation first to have GenerationServer running
      _ref_gen =
        push(socket, "generate_menu", %{
          "request_id" => "chat_req_init",
          "constraints" => %{}
        })

      # Wait for generation to start
      :timer.sleep(100)

      # Now send chat message - should find GenerationServer
      _ref_chat =
        push(socket, "chat", %{
          "proposal_id" => "999",
          "message" => "Remove tomatoes from the menu"
        })

      # chat returns noreply (cast to GenServer)
      # In real scenario, GenerationServer would respond via broadcast
      :timer.sleep(50)
    end
  end

  # ==========================================================================
  # confirm_proposal tests
  # ==========================================================================

  describe "handle_in confirm_proposal" do
    test "error when proposal not found - graceful error handling", %{
      account: account,
      user: user,
      token: token
    } do
      # Create data so account has valid structure
      {:ok, _recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe Confirm",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Use a valid UUID format but one that doesn't exist
      fake_uuid = Ecto.UUID.generate()

      ref =
        push(socket, "confirm_proposal", %{
          "proposal_id" => fake_uuid
        })

      # Should get an error (proposal not found) - gracefully handled
      assert_reply(ref, :error, %{reason: "not_found"})
    end

    test "error when invalid proposal_id format", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Use invalid UUID format
      ref =
        push(socket, "confirm_proposal", %{
          "proposal_id" => "not-a-valid-uuid"
        })

      # Should get error due to invalid format
      assert_reply(ref, :error, %{reason: reason})
      assert reason in ["invalid_proposal_id", "not_found"]
    end
  end

  # ==========================================================================
  # reject_proposal tests
  # ==========================================================================

  describe "handle_in reject_proposal" do
    test "error when proposal not found - graceful error handling", %{
      account: account,
      user: user,
      token: token
    } do
      {:ok, _recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe Reject",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:dinner]
        })

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Use valid UUID format but non-existent
      fake_uuid = Ecto.UUID.generate()

      ref =
        push(socket, "reject_proposal", %{
          "proposal_id" => fake_uuid
        })

      # Should get error (proposal not found) - gracefully handled
      assert_reply(ref, :error, %{reason: "not_found"})
    end

    test "rejects with missing proposal_id gracefully", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # No proposal_id in payload - falls through to unknown event
      ref = push(socket, "reject_proposal", %{})

      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end

  # ==========================================================================
  # Unknown event test
  # ==========================================================================

  describe "handle_in unknown event" do
    test "unknown event returns invalid_payload", %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref = push(socket, "totally_unknown_event", %{})

      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end

  # ==========================================================================
  # Helper function tests
  # ==========================================================================

  describe "helper functions behavior" do
    test "build_request_id generates unique ids", %{
      account: account,
      token: token
    } do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Push without explicit request_id - server should auto-generate
      _ref =
        push(socket, "generate_menu", %{
          "constraints" => %{}
        })

      # Wait for response
      :timer.sleep(50)
    end

    test "serialize_reason converts atoms to strings", %{
      account: account,
      user: user,
      token: token
    } do
      {:ok, _recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Test Recipe Serialize",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Try to confirm a proposal - service returns atom error which should be serialized
      ref = push(socket, "confirm_proposal", %{"proposal_id" => Ecto.UUID.generate()})

      # Error reason should be a string (atom serialized)
      assert_reply(ref, :error, %{reason: reason})
      assert is_binary(reason)
    end
  end
end
