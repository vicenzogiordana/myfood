defmodule MealPlannerApiWeb.PlanningAgentChannelTest do
  @moduledoc """
  Thin wiring tests for the planning agent channel adapter. Behaviour lives
  in `MealPlannerApi.PlanningAgent.SessionTest`.
  """

  use MealPlannerApiWeb.ChannelCase, async: false

  import MealPlannerApi.FactoryHelpers, only: [issue_access_v2_token: 2]
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Accounts.{Account, AccountMembership, User}
  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo
  alias MealPlannerApiWeb.{PlanningAgentChannel, UserSocket}

  defmodule FailingInitModel do
    @moduledoc false
    def init(_opts), do: {:error, {:unexpected, "detail"}}
  end

  @range %{"range_from" => "2026-11-02", "range_to" => "2026-11-02", "slots" => ["dinner"]}

  setup do
    household = household!()
    _ = persist_trial_window!(Repo.get!(Account, household.account_id), :eligible)
    recipe!("Fictitious soup", [ingredient!("Fictitious leek")], slots: ["dinner"])

    previous = Application.get_env(:meal_planner_api, :planning_agent)
    on_exit(fn -> Application.put_env(:meal_planner_api, :planning_agent, previous) end)

    configure_agent([
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:text, "Here is your dinner."}
    ])

    %{household: household}
  end

  defp configure_agent(script) do
    Application.put_env(:meal_planner_api, :planning_agent,
      model: {Scripted, script: script},
      optimizer: {FakeOptimizer, []}
    )
  end

  defp join!(household, member) do
    token =
      issue_access_v2_token(
        Repo.get!(User, member.user_id),
        Repo.get!(AccountMembership, member.membership_id)
      )

    {:ok, socket} = connect(UserSocket, %{"token" => token})

    {:ok, _reply, socket} =
      subscribe_and_join(socket, PlanningAgentChannel, "planning_agent:#{household.account_id}")

    socket
  end

  # Ends the session while the test still owns the sandbox connection.
  defp cancel!(socket) do
    ref = push(socket, "cancel_session", %{})
    assert_reply(ref, :ok, %{status: "cancelled"})
  end

  test "a Member cannot join another Household's agent channel", %{household: h} do
    other = household!("Other Fictitious Household")

    token =
      issue_access_v2_token(
        Repo.get!(User, h.owner.user_id),
        Repo.get!(AccountMembership, h.owner.membership_id)
      )

    {:ok, socket} = connect(UserSocket, %{"token" => token})

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(
               socket,
               PlanningAgentChannel,
               "planning_agent:#{other.account_id}"
             )
  end

  test "a Member starts a Planning Session; a second Member is told one is already active",
       %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, %{session_id: session_id})
    assert is_binary(session_id)

    other_socket = join!(h, member!(h))
    ref = push(other_socket, "start_session", @range)
    assert_reply(ref, :error, %{reason: "session_already_active"})

    cancel!(socket)
  end

  test "without consent the message is refused and the Member is asked for it",
       %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, _)

    ref = push(socket, "send_message", %{"text" => "Plan dinner"})
    assert_reply(ref, :error, %{reason: "consent_required"})
    assert_push("agent_event", %{"type" => "consent_required"})

    cancel!(socket)
  end

  test "a message over the size limit is refused with a typed reason", %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, _)

    ref = push(socket, "give_consent", %{})
    assert_reply(ref, :ok, _)

    too_long = String.duplicate("a", Session.max_message_bytes() + 1)
    ref = push(socket, "send_message", %{"text" => too_long})
    assert_reply(ref, :error, %{reason: "message_too_long"})
    refute_push("agent_event", %{"type" => "assistant_message"}, 100)

    cancel!(socket)
  end

  test "a message without text is refused with invalid_message", %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, _)

    ref = push(socket, "send_message", %{})
    assert_reply(ref, :error, %{reason: "invalid_message"})

    ref = push(socket, "send_message", %{"text" => 42})
    assert_reply(ref, :error, %{reason: "invalid_message"})

    cancel!(socket)
  end

  test "an overlapping range while a session is active is refused with a documented reason",
       %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "start_session", %{@range | "range_to" => "2026-11-04"})
    assert_reply(ref, :ok, _)

    # The Household lock is checked before the range overlap, so an
    # overlapping start is reported as session_already_active.
    other_socket = join!(h, member!(h))

    ref =
      push(other_socket, "start_session", %{
        @range
        | "range_from" => "2026-11-03",
          "range_to" => "2026-11-05"
      })

    assert_reply(ref, :error, %{reason: "session_already_active"})

    cancel!(socket)
  end

  test "a non-atom failure is replied as internal_error, never invalid_payload",
       %{household: h} do
    # A model whose init fails with a tuple reason stands in for any
    # changeset or tuple error surfacing from the session.
    Application.put_env(:meal_planner_api, :planning_agent,
      model: {__MODULE__.FailingInitModel, []},
      optimizer: {FakeOptimizer, []}
    )

    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :error, %{reason: "internal_error"})
  end

  test "a non-map start_session payload is refused with invalid_payload and the channel survives",
       %{household: h} do
    socket = join!(h, h.owner)

    for payload <- ["x", ["2026-11-02"]] do
      ref = push(socket, "start_session", payload)
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end

    assert Process.alive?(socket.channel_pid)
  end

  test "after consent a message produces a validated Proposal event", %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, %{session_id: session_id})

    ref = push(socket, "give_consent", %{})
    assert_reply(ref, :ok, _)

    ref = push(socket, "send_message", %{"text" => "Plan dinner"})
    assert_reply(ref, :ok, _)

    assert_push("agent_event", %{
      "type" => "proposal",
      "status" => "valid",
      "session_id" => ^session_id,
      "meals" => [%{"date" => "2026-11-02", "slot" => "dinner", "name" => "Fictitious soup"}]
    })

    assert_push("agent_event", %{"type" => "turn_completed"})
    cancel!(socket)
  end

  test "the Owner may cancel another Member's session", %{household: h} do
    member_socket = join!(h, member!(h))
    ref = push(member_socket, "start_session", @range)
    assert_reply(ref, :ok, _)

    owner_socket = join!(h, h.owner)
    cancel!(owner_socket)
    assert_push("agent_event", %{"type" => "session_cancelled"})
  end

  test "a Member stops the agent mid-turn and the session survives", %{household: h} do
    test_pid = self()

    configure_agent([
      fn _request ->
        send(test_pid, :model_blocked)
        Process.sleep(:infinity)
      end,
      {:text, "Ready when you are."}
    ])

    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, %{session_id: session_id})
    ref = push(socket, "give_consent", %{})
    assert_reply(ref, :ok, _)
    ref = push(socket, "send_message", %{"text" => "Plan dinner"})
    assert_reply(ref, :ok, _)
    assert_receive :model_blocked, 2_000

    ref = push(socket, "stop", %{})
    assert_reply(ref, :ok, %{status: "stopped"})
    assert_push("agent_event", %{"type" => "stopped", "session_id" => ^session_id})

    ref = push(socket, "send_message", %{"text" => "Try again"})
    assert_reply(ref, :ok, _)
    assert_push("agent_event", %{"type" => "assistant_message", "text" => "Ready when you are."})
    cancel!(socket)
  end

  test "the Owner cannot Stop another Member's session and a peer cannot Cancel it",
       %{household: h} do
    member_socket = join!(h, member!(h))
    ref = push(member_socket, "start_session", @range)
    assert_reply(ref, :ok, _)

    owner_socket = join!(h, h.owner)
    ref = push(owner_socket, "stop", %{})
    assert_reply(ref, :error, %{reason: "forbidden"})

    peer_socket = join!(h, member!(h))
    ref = push(peer_socket, "cancel_session", %{})
    assert_reply(ref, :error, %{reason: "forbidden"})

    cancel!(member_socket)
  end

  test "stop without an active session is refused", %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "stop", %{})
    assert_reply(ref, :error, %{reason: "no_active_session"})
  end

  test "cancelling a session that dies before replying keeps the channel alive",
       %{household: h} do
    socket = join!(h, h.owner)
    test_pid = self()

    # A stub registered as the Household's session: whereis finds it, then
    # it dies on the cancel call, as a session ending mid-lookup would.
    stub =
      spawn(fn ->
        {:ok, _} =
          Registry.register(
            MealPlannerApi.PlanningAgent.Registry,
            {:household, h.account_id},
            "stub"
          )

        send(test_pid, :registered)

        receive do
          {:"$gen_call", _from, _request} -> exit(:shutdown)
        end
      end)

    assert_receive :registered
    assert Session.whereis(h.account_id) == stub

    ref = push(socket, "cancel_session", %{})
    assert_reply(ref, :error, %{reason: "no_active_session"})
    assert Process.alive?(socket.channel_pid)
  end
end
