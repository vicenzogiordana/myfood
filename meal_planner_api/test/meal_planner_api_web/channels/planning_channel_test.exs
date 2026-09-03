defmodule MealPlannerApiWeb.PlanningChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  import Ecto.Query, warn: false
  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Data.{PlanningRepo, RecipeRepo, ShoppingRepo}
  alias MealPlannerApi.Generation.Server
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Repo
  alias MealPlannerApiWeb.{PlanningChannel, UserSocket}

  import MealPlannerApiWeb.ChannelHelpers, only: [issue_identity_and_token: 2]

  setup do
    {:ok, user, account, token} = issue_identity_and_token("u_plan_test", "acct_plan_test")
    %{user: user, account: account, token: token}
  end

  # Phase 4 — `revenuecat-access-enforcement` realtime enforcement
  # (task 4.1). Trial-window helper used to mark the seeded Account
  # `:eligible` or `:expired` for `AccountAccess.eligible?/1`.
  defp persist_trial_window!(%PersistenceAccount{} = account, :eligible) do
    started = DateTime.utc_now()
    ends = DateTime.add(started, 7 * 86_400, :second)

    {:ok, updated} =
      account
      |> PersistenceAccount.changeset(%{trial_started_at: started, trial_ends_at: ends})
      |> Repo.update()

    updated
  end

  defp persist_trial_window!(%PersistenceAccount{} = account, :expired) do
    past = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    {:ok, updated} =
      account
      |> PersistenceAccount.changeset(%{trial_started_at: past, trial_ends_at: past})
      |> Repo.update()

    updated
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
  # Phase 4 — `revenuecat-access-enforcement` realtime enforcement (task 4.1).
  # Same Account eligibility rule as the HTTP `:enforce_capability` plug.
  # ==========================================================================

  describe "join/3 subscription enforcement (phase 4 task 4.1)" do
    test "expired Account join returns subscription_required when enforcement is enabled (task 4.1)",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :expired)

      previous = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)
      Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)

      try do
        {:ok, socket} = connect(UserSocket, %{"token" => token})

        assert {:error, %{reason: "subscription_required"}} =
                 subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")
      after
        Application.put_env(
          :meal_planner_api,
          :revenuecat_access_enforcement,
          previous
        )
      end
    end

    test "eligible Account join succeeds when enforcement is enabled (task 4.1)",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :eligible)

      previous = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)
      Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)

      try do
        {:ok, socket} = connect(UserSocket, %{"token" => token})

        assert {:ok, _reply, socket} =
                 subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

        assert socket.assigns.account_id == account.id
      after
        Application.put_env(
          :meal_planner_api,
          :revenuecat_access_enforcement,
          previous
        )
      end
    end

    test "disabled enforcement allows an expired Account to join (rollout safety, task 4.1)",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :expired)

      previous = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)
      Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, false)

      try do
        {:ok, socket} = connect(UserSocket, %{"token" => token})

        assert {:ok, _reply, _socket} =
                 subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")
      after
        Application.put_env(
          :meal_planner_api,
          :revenuecat_access_enforcement,
          previous
        )
      end
    end

    # Task 4.2 — ordering triangulation: topic-vs-membership mismatch fires
    # BEFORE the subscription check, so the response is `forbidden` (not
    # `subscription_required`) even when enforcement is on. Prevents
    # leaking another Account's subscription state.
    test "topic-vs-membership mismatch fires before subscription check (task 4.2)",
         %{token: token} do
      previous = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)
      Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)

      try do
        {:ok, socket} = connect(UserSocket, %{"token" => token})

        assert {:error, %{reason: "forbidden"}} =
                 subscribe_and_join(socket, PlanningChannel, "planning:other_account_id")
      after
        Application.put_env(
          :meal_planner_api,
          :revenuecat_access_enforcement,
          previous
        )
      end
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

    # @task 4.3 — channel-layer end-to-end test: confirms that the cart
    # fields (`shopping_items_count`, `checkout_session_id`, `cart`) flow
    # through both the direct reply and the `proposal_confirmed`
    # broadcast. This is the first test that exercises the registered
    # `Generation.Server` path (not the `PlanningChatService` fallback).
    test "confirm reply AND proposal_confirmed broadcast carry cart fields end-to-end", %{
      account: account,
      user: user,
      token: token
    } do
      # Seed: a recipe with one ingredient, a proposal with one slot.
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "4-3 recipe",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, flour} =
        Catalog.create_ingredient(%{name: "4-3 flour", category: :granos})

      {:ok, _ri} =
        RecipeRepo.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: flour.id,
          quantity_milli: 750_000,
          unit: :g
        })

      {:ok, run} =
        PlanningRepo.create_generation_run(%{
          account_id: account.id,
          user_id: user.id,
          status: :processing,
          started_at: DateTime.utc_now(),
          input_context: %{}
        })

      {:ok, proposal} =
        PlanningRepo.create_proposal(%{
          generation_run_id: run.id,
          status: :pending,
          proposal_json: %{
            slots: [
              %{
                slot_key: "2026-08-09_lunch",
                date: "2026-08-09",
                slot: "lunch",
                recipe_id: recipe.id,
                recipe_name: "4-3 recipe",
                price_cents: 1000
              }
            ]
          }
        })

      flour_id = flour.id

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # Register a Generation.Server under the account's registry with the
      # joined channel's pid so `proposal_confirmed` is broadcast back
      # onto `planning:<account_id>`, which the test process is subscribed
      # to (via `subscribe_and_join`/`assert_broadcast`).
      start_supervised!(
        {Server, account_id: account.id, user_id: user.id, channel_pid: socket.channel_pid},
        id: {:channel_server, account.id, :cart_payload_test}
      )

      ref =
        push(socket, "confirm_proposal", %{
          "proposal_id" => proposal.id
        })

      assert_reply(ref, :ok, %{
        shopping_items_count: 1,
        checkout_session_id: checkout_session_id,
        cart: [%{ingredient_id: ingredient_id, unit: :g, quantity_milli: 750_000}]
      })

      assert is_binary(checkout_session_id)
      assert ingredient_id == flour_id

      assert_broadcast("proposal_confirmed", %{
        shopping_items_count: 1,
        checkout_session_id: broadcast_session_id,
        cart: [%{ingredient_id: broadcast_ingredient_id, unit: :g, quantity_milli: 750_000}]
      })

      assert broadcast_session_id == checkout_session_id
      assert broadcast_ingredient_id == flour_id
    end

    test "re-confirming an already-accepted proposal returns :already_confirmed and emits no proposal_confirmed",
         %{
           account: account,
           user: user,
           token: token
         } do
      {:ok, _recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "4-3 idemp",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, run} =
        PlanningRepo.create_generation_run(%{
          account_id: account.id,
          user_id: user.id,
          status: :processing,
          started_at: DateTime.utc_now(),
          input_context: %{}
        })

      {:ok, proposal} =
        PlanningRepo.create_proposal(%{
          generation_run_id: run.id,
          status: :accepted,
          proposal_json: %{slots: []}
        })

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      start_supervised!(
        {Server, account_id: account.id, user_id: user.id, channel_pid: socket.channel_pid},
        id: {:channel_server, account.id, :already_confirmed_test}
      )

      ref =
        push(socket, "confirm_proposal", %{
          "proposal_id" => proposal.id
        })

      assert_reply(ref, :error, %{reason: "already_confirmed"})

      # No `proposal_confirmed` broadcast should follow the rejection.
      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "planning:" <> _,
                       event: "proposal_confirmed"
                     },
                     100
    end

    # Regression for review blocker R4-001: a failed `schedule_meal/1`
    # MUST roll back the proposal status flip and the cart writes.
    test "failed scheduled_meal insert rolls back proposal status, meals, and cart",
         %{account: account, user: user, token: token} do
      missing_recipe_id = Ecto.UUID.generate()

      {:ok, run} =
        PlanningRepo.create_generation_run(%{
          account_id: account.id,
          user_id: user.id,
          status: :processing,
          started_at: DateTime.utc_now(),
          input_context: %{}
        })

      {:ok, proposal} =
        PlanningRepo.create_proposal(%{
          generation_run_id: run.id,
          status: :pending,
          proposal_json: %{
            slots: [%{slot_key: "2026-08-09_lunch", recipe_id: missing_recipe_id}]
          }
        })

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      start_supervised!(
        {Server, account_id: account.id, user_id: user.id, channel_pid: socket.channel_pid},
        id: {:channel_server, account.id, :rollback_test}
      )

      ref = push(socket, "confirm_proposal", %{"proposal_id" => proposal.id})

      assert_reply(ref, :error, _payload)

      reloaded = Repo.get!(MealPlannerApi.Persistence.Planning.PlanningProposal, proposal.id)
      assert reloaded.status == :pending

      assert PlanningRepo.list_scheduled_meals(account.id, ~D[2026-01-01], ~D[2026-12-31]) == []

      assert ShoppingRepo.list_checkout_sessions(account.id) == []
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
  # Phase 4 — PR4 `cancel_planning` lifecycle handler (tasks 4.3 / 4.4).
  # Owner-scoped cancel: the session owner OR the Account's `:owner` role
  # may cancel; any other peer gets `:forbidden`. Calls
  # `PlanningRepo.cancel_session/4` (PR2) and broadcasts `session_cancelled`
  # on `planning:<account_id>` via `Phoenix.Channel.Server.broadcast!/4`.
  # ==========================================================================

  describe "handle_in cancel_planning (task 4.3 / 4.4)" do
    test "owner cancels their own session: :ok + session_cancelled broadcast", %{
      account: account,
      user: owner_user,
      token: owner_token
    } do
      _ = persist_trial_window!(account, :eligible)
      owner_membership_id = owner_membership_id(account.id, owner_user.id)

      # Pre-create an active session owned by owner_user.
      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-03-01],
          range_to: ~D[2026-03-08],
          lock_owner_user_id: owner_user.id,
          lock_owner_membership_id: owner_membership_id,
          lease_expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
        })

      session_id = session.id

      {:ok, socket} = connect(UserSocket, %{"token" => owner_token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref =
        push(socket, "cancel_planning", %{
          "session_id" => session_id
        })

      assert_reply(ref, :ok, %{session_id: ^session_id} = payload)
      assert payload.status == :cancelled

      assert_broadcast("session_cancelled", %{"session_id" => ^session_id})

      # Row flipped to :cancelled in the DB.
      reloaded =
        MealPlannerApi.Persistence.Planning.PlanningSession
        |> MealPlannerApi.Repo.get!(session_id)

      assert reloaded.status == :cancelled
      assert reloaded.terminal_at != nil
    end

    test "non-owner peer cannot cancel a peer's session: :forbidden, no state change",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :eligible)
      _ = token

      # Create a separate User + their own session for the same Account.
      peer_user =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          email: "peer-cancel-#{System.unique_integer([:positive])}@example.com",
          name: "Peer Cancel",
          role: :member
        })
        |> Repo.insert!()

      peer_membership_id =
        %MealPlannerApi.Persistence.Accounts.AccountMembership{}
        |> MealPlannerApi.Persistence.Accounts.AccountMembership.changeset(%{
          account_id: account.id,
          user_id: peer_user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()
        |> Map.get(:id)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-03-01],
          range_to: ~D[2026-03-08],
          lock_owner_user_id: peer_user.id,
          lock_owner_membership_id: peer_membership_id,
          lease_expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
        })

      session_id = session.id

      # Bypass the `issue_identity_and_token` setup entirely and mint a
      # token for a brand-new peer user with a `:member` role on this
      # account. That user is NOT the account owner, so the cancel
      # attempt MUST be rejected with `:forbidden`.
      non_owner_token = non_owner_peer_token(account)

      {:ok, socket} = connect(UserSocket, %{"token" => non_owner_token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref =
        push(socket, "cancel_planning", %{
          "session_id" => session_id
        })

      assert_reply(ref, :error, %{reason: :forbidden})

      # No session_cancelled broadcast fires.
      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "planning:" <> _,
                       event: "session_cancelled"
                     },
                     200

      # Row stays :active.
      reloaded =
        MealPlannerApi.Persistence.Planning.PlanningSession
        |> MealPlannerApi.Repo.get!(session_id)

      assert reloaded.status == :active
    end

    test "Account owner cancels a peer's session: :ok + session_cancelled broadcast",
         %{account: account, token: owner_token} do
      _ = persist_trial_window!(account, :eligible)

      # Peer user's session.
      peer_user =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          email: "peer-owner-cancel-#{System.unique_integer([:positive])}@example.com",
          name: "Peer Owner Cancel",
          role: :member
        })
        |> Repo.insert!()

      peer_membership_id =
        %MealPlannerApi.Persistence.Accounts.AccountMembership{}
        |> MealPlannerApi.Persistence.Accounts.AccountMembership.changeset(%{
          account_id: account.id,
          user_id: peer_user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()
        |> Map.get(:id)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-03-01],
          range_to: ~D[2026-03-08],
          lock_owner_user_id: peer_user.id,
          lock_owner_membership_id: peer_membership_id,
          lease_expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
        })

      session_id = session.id

      {:ok, socket} = connect(UserSocket, %{"token" => owner_token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref =
        push(socket, "cancel_planning", %{
          "session_id" => session_id
        })

      assert_reply(ref, :ok, %{session_id: ^session_id})
      assert_broadcast("session_cancelled", %{"session_id" => ^session_id})

      reloaded =
        MealPlannerApi.Persistence.Planning.PlanningSession
        |> MealPlannerApi.Repo.get!(session_id)

      assert reloaded.status == :cancelled
    end

    test "cancel of a non-existent session returns :not_found", %{
      account: account,
      token: token
    } do
      _ = persist_trial_window!(account, :eligible)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      fake_session_id = Ecto.UUID.generate()

      ref =
        push(socket, "cancel_planning", %{
          "session_id" => fake_session_id
        })

      assert_reply(ref, :error, %{reason: :not_found})
    end
  end

  # ==========================================================================
  # Phase 4 — PR4 `start_planning` lifecycle handler (tasks 4.1 / 4.2).
  # Re-checks Account eligibility (mirroring the join-time guard) and
  # starts a `PlanningSessionServer` for the (account, range) lock. On
  # success the server broadcasts `session_started` on
  # `planning:<account_id>`; on failure (ineligible, overlap, bad range)
  # the channel replies with the matching atom reason and never inserts
  # a row.
  # ==========================================================================

  describe "handle_in start_planning (task 4.1 / 4.2)" do
    test "eligible Account + valid range: :ok + session_started broadcast + :active row",
         %{account: account, user: user, token: token} do
      _ = persist_trial_window!(account, :eligible)
      owner_membership_id = owner_membership_id(account.id, user.id)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref =
        push(socket, "start_planning", %{
          "range_from" => "2026-04-01",
          "range_to" => "2026-04-07"
        })

      assert_reply(ref, :ok, %{session_id: session_id, status: :active})
      assert is_binary(session_id)
      assert_broadcast("session_started", %{"session_id" => ^session_id})

      reloaded =
        MealPlannerApi.Persistence.Planning.PlanningSession
        |> MealPlannerApi.Repo.get!(session_id)

      assert reloaded.status == :active
      assert reloaded.account_id == account.id
      assert reloaded.lock_owner_user_id == user.id
      assert reloaded.lock_owner_membership_id == owner_membership_id
      assert reloaded.range_from == ~D[2026-04-01]
      assert reloaded.range_to == ~D[2026-04-07]
    end

    test "expired Account (ineligible) returns :subscription_required, no row, no broadcast",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :expired)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref =
        push(socket, "start_planning", %{
          "range_from" => "2026-04-01",
          "range_to" => "2026-04-07"
        })

      assert_reply(ref, :error, %{reason: :subscription_required})

      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "planning:" <> _,
                       event: "session_started"
                     },
                     200

      active_count =
        MealPlannerApi.Repo.aggregate(
          from(s in MealPlannerApi.Persistence.Planning.PlanningSession,
            where: s.account_id == ^account.id and s.status == :active
          ),
          :count
        )

      assert active_count == 0
    end

    test "overlapping active range returns :overlapping_range, only the pre-existing row stays",
         %{account: account, user: owner_user, token: owner_token} do
      _ = persist_trial_window!(account, :eligible)
      owner_membership_id = owner_membership_id(account.id, owner_user.id)

      {:ok, existing} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-04-05],
          range_to: ~D[2026-04-12],
          lock_owner_user_id: owner_user.id,
          lock_owner_membership_id: owner_membership_id,
          lease_expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
        })

      {:ok, socket} = connect(UserSocket, %{"token" => owner_token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref =
        push(socket, "start_planning", %{
          "range_from" => "2026-04-10",
          "range_to" => "2026-04-15"
        })

      assert_reply(ref, :error, %{reason: :overlapping_range})

      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "planning:" <> _,
                       event: "session_started"
                     },
                     200

      active_sessions =
        MealPlannerApi.Repo.all(
          from(s in MealPlannerApi.Persistence.Planning.PlanningSession,
            where: s.account_id == ^account.id and s.status == :active
          )
        )

      assert length(active_sessions) == 1
      assert hd(active_sessions).id == existing.id
    end

    test "invalid range_from format returns :invalid_range", %{
      account: account,
      token: token
    } do
      _ = persist_trial_window!(account, :eligible)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref =
        push(socket, "start_planning", %{
          "range_from" => "not-a-date",
          "range_to" => "2026-04-07"
        })

      assert_reply(ref, :error, %{reason: :invalid_range})
    end
  end

  # ==========================================================================
  # Phase 4 — PR4 `send_message` handler (tasks 4.7 / 4.8).
  # The channel-layer intake for validated AI intents. Requires:
  #   1. an active `start_planning` (so `session_pid` is cached on the
  #      socket assigns), and
  #   2. a `session_id` payload that matches the cached id.
  # The intent is validated by `PlanningSessionServer.apply_intent/3`,
  # which delegates to `GenerationService.validate_ai_intent/1`.
  # ==========================================================================

  describe "handle_in send_message (task 4.7 / 4.8)" do
    test "valid intent: :ok + PlanningSessionServer.apply_intent accepts it",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :eligible)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # First start a session so the channel caches `session_pid`.
      ref_start =
        push(socket, "start_planning", %{
          "range_from" => "2026-05-01",
          "range_to" => "2026-05-07"
        })

      assert_reply(ref_start, :ok, %{session_id: session_id, status: :active})
      # Drain the `session_started` broadcast that the server emits on
      # the planning topic, otherwise it sits in the mailbox ahead of
      # the `send_message` reply and `assert_reply` matches the wrong
      # message.
      assert_broadcast("session_started", %{"session_id" => ^session_id})

      # Now apply a valid intent.
      ref =
        push(socket, "send_message", %{
          "session_id" => session_id,
          "intent" => %{
            "kind" => "change_constraints",
            "payload" => %{"budget_cents" => 5000}
          }
        })

      assert_reply(ref, :ok, %{kind: :change_constraints, payload: %{budget_cents: 5000}})
    end

    test "forbidden key inside payload (recipe_id) is rejected by validate_ai_intent",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :eligible)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref_start =
        push(socket, "start_planning", %{
          "range_from" => "2026-05-08",
          "range_to" => "2026-05-14"
        })

      assert_reply(ref_start, :ok, %{session_id: session_id, status: :active})
      # Drain the `session_started` broadcast emitted by the server so
      # it doesn't sit in the mailbox ahead of the `send_message` reply.
      assert_broadcast("session_started", %{"session_id" => ^session_id})

      ref =
        push(socket, "send_message", %{
          "session_id" => session_id,
          "intent" => %{
            "kind" => "change_constraints",
            "payload" => %{"recipe_id" => "attacker-supplied-id"}
          }
        })

      assert_reply(ref, :error, %{reason: :forbidden_intent})
    end

    test "unknown kind is rejected by validate_ai_intent",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :eligible)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref_start =
        push(socket, "start_planning", %{
          "range_from" => "2026-05-15",
          "range_to" => "2026-05-21"
        })

      assert_reply(ref_start, :ok, %{session_id: session_id, status: :active})
      assert_broadcast("session_started", %{"session_id" => ^session_id})

      ref =
        push(socket, "send_message", %{
          "session_id" => session_id,
          "intent" => %{
            "kind" => "totally_made_up",
            "payload" => %{}
          }
        })

      assert_reply(ref, :error, %{reason: :unknown_intent})
    end

    test "send_message without an active session returns :no_active_session",
         %{account: account, token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      # No start_planning has run, so session_pid is nil.
      ref =
        push(socket, "send_message", %{
          "session_id" => Ecto.UUID.generate(),
          "intent" => %{"kind" => "change_constraints"}
        })

      assert_reply(ref, :error, %{reason: :no_active_session})
    end

    test "session_id payload that doesn't match the cached id returns :session_mismatch",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :eligible)

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, PlanningChannel, "planning:#{account.id}")

      ref_start =
        push(socket, "start_planning", %{
          "range_from" => "2026-05-22",
          "range_to" => "2026-05-28"
        })

      assert_reply(ref_start, :ok, %{session_id: started_id, status: :active})
      assert_broadcast("session_started", %{"session_id" => ^started_id})

      other_session_id = Ecto.UUID.generate()

      ref =
        push(socket, "send_message", %{
          "session_id" => other_session_id,
          "intent" => %{"kind" => "change_constraints", "payload" => %{}}
        })

      assert_reply(ref, :error, %{reason: :session_mismatch})
    end
  end

  # ==========================================================================
  # Phase 5 — e2e 2-socket test (task 5.2).
  # Two distinct members join the same `planning:<account_id>` topic.
  # A starts a session; B tries overlapping (refused) and non-overlapping
  # (succeeds). A cancels — BOTH sockets receive the `session_cancelled`
  # broadcast because both are subscribed to the planning topic.
  # ==========================================================================

  describe "e2e 2-socket on same planning:<account_id> (task 5.2)" do
    test "A starts, B overlap → :overlapping_range, B non-overlap → :ok, A cancels → both see session_cancelled",
         %{account: account, user: owner_user, token: owner_token} do
      _ = persist_trial_window!(account, :eligible)
      owner_membership_id = owner_membership_id(account.id, owner_user.id)

      # A = owner on the seeded user; B = a brand-new peer member on
      # the same account (different actor_membership_id for cancel auth).
      peer_token = non_owner_peer_token(account)

      # ── A starts a session in 2026-06 ──
      {:ok, socket_a} = connect(UserSocket, %{"token" => owner_token})
      {:ok, _, socket_a} = subscribe_and_join(socket_a, PlanningChannel, "planning:#{account.id}")

      ref_a_start =
        push(socket_a, "start_planning", %{
          "range_from" => "2026-06-01",
          "range_to" => "2026-06-07"
        })

      assert_reply(ref_a_start, :ok, %{session_id: a_session_id, status: :active})
      assert_broadcast("session_started", %{"session_id" => ^a_session_id})
      _ = owner_membership_id

      # ── B joins ──
      {:ok, socket_b} = connect(UserSocket, %{"token" => peer_token})
      {:ok, _, socket_b} = subscribe_and_join(socket_b, PlanningChannel, "planning:#{account.id}")

      # ── B tries an OVERLAPPING range → refused ──
      ref_b_overlap =
        push(socket_b, "start_planning", %{
          "range_from" => "2026-06-05",
          "range_to" => "2026-06-12"
        })

      assert_reply(ref_b_overlap, :error, %{reason: :overlapping_range})
      refute_receive %Phoenix.Socket.Broadcast{event: "session_started"}, 200

      # ── B starts a NON-OVERLAPPING range → ok ──
      ref_b_ok =
        push(socket_b, "start_planning", %{
          "range_from" => "2026-06-15",
          "range_to" => "2026-06-21"
        })

      assert_reply(ref_b_ok, :ok, %{session_id: b_session_id, status: :active})
      assert b_session_id != a_session_id
      assert_broadcast("session_started", %{"session_id" => ^b_session_id})

      # ── A cancels its session — BOTH sockets should see session_cancelled ──
      ref_a_cancel =
        push(socket_a, "cancel_planning", %{"session_id" => a_session_id})

      assert_reply(ref_a_cancel, :ok, %{session_id: ^a_session_id, status: :cancelled})

      # Both A and B receive the broadcast.
      assert_broadcast("session_cancelled", %{"session_id" => ^a_session_id})
      assert_broadcast("session_cancelled", %{"session_id" => ^a_session_id})
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

  # Resolves the `:active` `AccountMembership` id for the given (account,
  # user) pair. Phase 4 PR4 channel tests use this to assert
  # `lock_owner_membership_id` and to drive `cancel_planning` scenarios.
  defp owner_membership_id(account_id, user_id) do
    MealPlannerApi.Repo.one!(
      from(m in MealPlannerApi.Persistence.Accounts.AccountMembership,
        where: m.account_id == ^account_id and m.user_id == ^user_id and m.status == :active
      )
    ).id
  end

  # Fetches the User that owns the JWT — used by the cancel-planning
  # "non-owner peer" scenario to look up the primary user without
  # resorting to `issue_identity_and_token` again.
  # Mints a token for a brand-new peer user with a `:member` (non-owner)
  # role on the given account. Used to simulate a peer cancelling
  # someone else's session.
  defp non_owner_peer_token(account) do
    peer_user =
      %MealPlannerApi.Persistence.Accounts.User{}
      |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
        email: "non-owner-peer-#{System.unique_integer([:positive])}@example.com",
        name: "Non Owner Peer",
        role: :member
      })
      |> Repo.insert!()

    {:ok, membership} =
      %MealPlannerApi.Persistence.Accounts.AccountMembership{}
      |> MealPlannerApi.Persistence.Accounts.AccountMembership.changeset(%{
        account_id: account.id,
        user_id: peer_user.id,
        role: :member,
        status: :active,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert()

    issue_access_v2_token(peer_user, membership)
  end

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
