defmodule MealPlannerApiWeb.AIChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApiWeb.{AIChannel, UserSocket}

  setup do
    {:ok, user, account, token} = issue_identity_and_token("u_ai_test", "acct_ai_test")
    %{user: user, account: account, token: token}
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

  # ==========================================================================
  # Phase 4 — `revenuecat-access-enforcement` realtime enforcement (task 4.1).
  # The single Account eligibility rule (`AccountAccess.eligible?/1`) is
  # shared between HTTP `:enforce_capability` and every product channel
  # join. AIChannel's topic is `ai_chat:<room_id>` (no account id in the
  # topic — see task 3.12) so the subscription guard fires purely off the
  # membership's `account_id`, exactly like the other three channels.
  # ==========================================================================

  describe "join/3 subscription enforcement (phase 4 task 4.1)" do
    test "expired Account join returns subscription_required when enforcement is enabled (task 4.1)",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :expired)

      with_enforcement_enabled!(fn ->
        {:ok, socket} = connect(UserSocket, %{"token" => token})

        assert {:error, %{reason: "subscription_required"}} =
                 subscribe_and_join(socket, AIChannel, "ai_chat:expired_room")
      end)
    end

    test "eligible Account join succeeds when enforcement is enabled (task 4.1)",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :eligible)

      with_enforcement_enabled!(fn ->
        {:ok, socket} = connect(UserSocket, %{"token" => token})

        assert {:ok, _reply, socket} =
                 subscribe_and_join(socket, AIChannel, "ai_chat:eligible_room")

        assert socket.assigns.current_membership.account_id == account.id
      end)
    end

    test "disabled enforcement allows an expired Account to join (rollout safety, task 4.1)",
         %{account: account, token: token} do
      _ = persist_trial_window!(account, :expired)

      with_enforcement_disabled!(fn ->
        {:ok, socket} = connect(UserSocket, %{"token" => token})

        assert {:ok, _reply, _socket} =
                 subscribe_and_join(socket, AIChannel, "ai_chat:rollout_disabled_room")
      end)
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

    # Post-PR-3c review — BLOCKER fix: AIChannel is the only Phase A
    # surface that was never brought into the "single choke point"
    # pattern (task 3.14-3.22 — see AccountScopeHelpers.
    # scope_user_to_membership/2). It read `socket.assigns.current_user`
    # straight off the JWT and handed it to `AI.stream_response/4`,
    # which resolves budget/subscription via `user.account_id` — the
    # claim-derived, NOT the DB-resolved `current_membership.account_id`
    # value. Same tampered-claim RED-discriminator technique as the
    # rest of this PR (see calendar_controller_test.exs task 3.14):
    # `membership_id` in the claims points at the real, canonical
    # membership (Account B); the redundant `account_id` claim is
    # tampered to point at a DIFFERENT account (Account A) the socket
    # has no active membership in.
    #
    # Test-level note: this test originally could only assert the
    # tenancy fix indirectly (via a crash-log capture) because two
    # SEPARATE, pre-existing bugs unrelated to tenancy made the
    # "new_message" happy path crash unconditionally — see
    # `fix/ai-chat-stream-crash` — `AI.stream_response/4`'s
    # `%MealPlannerApi.Accounts.User{}` guard could never match the real
    # `Persistence.Accounts.User` struct every caller passes, and (once
    # past that) `MockClient`/`GeminiClient`'s
    # `get_in(opts, [:user, :account_id])` could not traverse an Ecto
    # struct (no `Access` behaviour). Now that both are fixed, this test
    # asserts the real, positive outcome directly: the
    # `ai_response_started` broadcast carries the DB-resolved Account B
    # id, never the tampered Account A claim.
    test "new_message threads current_membership.account_id into AI.stream_response/4, not a tampered account_id claim" do
      user =
        user_with_memberships(%{email: "ai_tamper@example.com"}, [
          {%{plan: :family_4, name: "AI Tamper Account A"}, :owner},
          {%{plan: :family_4, name: "AI Tamper Account B"}, :member}
        ])

      [membership_a, membership_b] = user.memberships

      tampered_claims =
        MealPlannerApi.AccountsMembership.claims_for(user, membership_b)
        |> Map.put("account_id", to_string(membership_a.account_id))

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, tampered_claims, token_type: "access")

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, AIChannel, "ai_chat:tamper_room")

      assert socket.assigns.current_membership.account_id == membership_b.account_id

      push(socket, "new_message", %{"message" => "hola"})

      account_id_b = membership_b.account_id

      assert_broadcast("ai_response_started", %{account_id: ^account_id_b})
    end
  end

  # ==========================================================================
  # Phase 4 — PR4 `AIChannel` typed-intent boundary (tasks 4.5 / 4.6).
  # The `new_message` handler validates the optional `intent` payload
  # against `GenerationService.validate_ai_intent/1` and, on success,
  # broadcasts `send_intent` on `planning:<account_id>`. On failure
  # (`forbidden_intent`, `unknown_intent`, `invalid_payload`) the
  # channel short-circuits: the AI stream is NOT started and the
  # caller gets the matching atom reason. The existing AI stream
  # flow is preserved when no intent is supplied (backward compat).
  # ==========================================================================

  describe "handle_in new_message intent boundary (task 4.5 / 4.6)" do
    test "valid intent: broadcast send_intent on planning topic, AI stream runs",
         %{account: account, token: token} do
      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "planning:#{account.id}")

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, AIChannel, "ai_chat:valid_intent")

      push(socket, "new_message", %{
        "message" => "ajusta el budget",
        "intent" => %{
          "kind" => "change_constraints",
          "payload" => %{"budget_cents" => 5000}
        }
      })

      assert_broadcast("send_intent", %{
        "intent" => %{kind: :change_constraints, payload: %{budget_cents: 5000}}
      })
    end

    test "forbidden key (recipe_id) inside intent payload: :forbidden_intent, no broadcast, no stream",
         %{account: account, token: token} do
      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "planning:#{account.id}")

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, AIChannel, "ai_chat:forbidden_intent")

      ref =
        push(socket, "new_message", %{
          "message" => "ajusta el budget",
          "intent" => %{
            "kind" => "change_constraints",
            "payload" => %{"recipe_id" => "attacker-supplied-id"}
          }
        })

      assert_reply(ref, :error, %{reason: :forbidden_intent})

      # No `send_intent` broadcast on the planning topic.
      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "planning:" <> _,
                       event: "send_intent"
                     },
                     100

      # The AI stream must NOT have started (no `ai_response_started`
      # broadcast on the ai_chat topic either).
      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "ai_chat:" <> _,
                       event: "ai_response_started"
                     },
                     100
    end

    test "unknown :kind: :unknown_intent, no broadcast",
         %{account: account, token: token} do
      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "planning:#{account.id}")

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, AIChannel, "ai_chat:unknown_intent")

      ref =
        push(socket, "new_message", %{
          "message" => "ajusta el budget",
          "intent" => %{
            "kind" => "totally_made_up",
            "payload" => %{}
          }
        })

      assert_reply(ref, :error, %{reason: :unknown_intent})

      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "planning:" <> _,
                       event: "send_intent"
                     },
                     100
    end

    test "non-map intent: :invalid_payload, no broadcast",
         %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _reply, socket} = subscribe_and_join(socket, AIChannel, "ai_chat:bad_intent")

      ref = push(socket, "new_message", %{"message" => "hola", "intent" => "not-a-map"})

      assert_reply(ref, :error, %{reason: :invalid_payload})
    end

    test "no intent supplied: AI stream runs as before, no send_intent broadcast",
         %{account: account, token: token} do
      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "planning:#{account.id}")

      {:ok, socket} = connect(UserSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, AIChannel, "ai_chat:no_intent")

      push(socket, "new_message", %{"message" => "hola"})

      # The AI stream should still start (backward compat).
      assert_broadcast("ai_response_started", _)

      # No `send_intent` broadcast — there was no intent.
      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "planning:" <> _,
                       event: "send_intent"
                     },
                     100
    end
  end
end
