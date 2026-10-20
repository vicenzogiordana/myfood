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
    # Keeps the rest of the configuration, such as the start rate limit.
    configured = Application.get_env(:meal_planner_api, :planning_agent, [])

    Application.put_env(
      :meal_planner_api,
      :planning_agent,
      Keyword.merge(configured, model: {Scripted, script: script}, optimizer: {FakeOptimizer, []})
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

  test "the planning topic serves the agent flow only", %{household: h} do
    token =
      issue_access_v2_token(
        Repo.get!(User, h.owner.user_id),
        Repo.get!(AccountMembership, h.owner.membership_id)
      )

    {:ok, socket} = connect(UserSocket, %{"token" => token})

    # Routed by the socket, not by naming the module.
    {:ok, _reply, socket} = subscribe_and_join(socket, "planning:#{h.account_id}", %{})
    assert socket.channel == PlanningAgentChannel

    # Legacy events are no longer served.
    for {event, payload} <- [
          {"generate_menu", %{"constraints" => %{}}},
          {"chat", %{"message" => "cambia el lunes", "proposal_id" => Ecto.UUID.generate()}},
          {"confirm_proposal", %{"proposal_id" => Ecto.UUID.generate()}},
          {"start_planning", %{"range_from" => "2026-11-02", "range_to" => "2026-11-02"}}
        ] do
      ref = push(socket, event, payload)
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end

    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, %{session_id: session_id})
    assert is_binary(session_id)

    cancel!(socket)
  end

  test "a Member cannot join the planning topic of another Household", %{household: h} do
    other = household!("Other Fictitious Household")

    token =
      issue_access_v2_token(
        Repo.get!(User, h.owner.user_id),
        Repo.get!(AccountMembership, h.owner.membership_id)
      )

    {:ok, socket} = connect(UserSocket, %{"token" => token})

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, "planning:#{other.account_id}", %{})
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
    Application.put_env(
      :meal_planner_api,
      :planning_agent,
      Keyword.put(
        Application.get_env(:meal_planner_api, :planning_agent),
        :model,
        {__MODULE__.FailingInitModel, []}
      )
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

  test "after a limit the Member authorizes continuing through the channel", %{household: h} do
    search = {:tool_calls, [{"search_recipes", %{"query" => "soup"}}]}
    configure_agent(List.duplicate(search, 4) ++ [{:text, "Continued."}])

    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, _)
    ref = push(socket, "give_consent", %{})
    assert_reply(ref, :ok, _)

    ref = push(socket, "authorize_continuation", %{})
    assert_reply(ref, :error, %{reason: "no_limit_reached"})

    ref = push(socket, "send_message", %{"text" => "Plan dinner"})
    assert_reply(ref, :ok, _)

    assert_push("agent_event", %{
      "type" => "limit_reached",
      "limit" => "no_progress",
      "requires_authorization" => true
    })

    ref = push(socket, "authorize_continuation", %{})
    assert_reply(ref, :ok, _)

    assert_push("agent_event", %{"type" => "assistant_message", "text" => "Continued."})
    cancel!(socket)
  end

  # Issue #158: a new message after a limit authorizes continuing by itself.
  test "after a limit a new message starts a new run through the channel", %{household: h} do
    search = {:tool_calls, [{"search_recipes", %{"query" => "soup"}}]}
    configure_agent(List.duplicate(search, 4) ++ [{:text, "Planned without soup."}])

    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, _)
    ref = push(socket, "give_consent", %{})
    assert_reply(ref, :ok, _)

    ref = push(socket, "send_message", %{"text" => "Plan dinner"})
    assert_reply(ref, :ok, _)
    assert_push("agent_event", %{"type" => "limit_reached", "limit" => "no_progress"})

    ref = push(socket, "send_message", %{"text" => "Forget the soup"})
    assert_reply(ref, :ok, _)

    assert_push("agent_event", %{"type" => "assistant_message", "text" => "Planned without soup."})

    cancel!(socket)
  end

  test "an exhausted budget is forwarded with its message and the latest Proposal",
       %{household: h} do
    configure_agent([
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:error, :spend_cap_reached}
    ])

    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, %{session_id: session_id})
    ref = push(socket, "give_consent", %{})
    assert_reply(ref, :ok, _)

    ref = push(socket, "send_message", %{"text" => "Plan dinner"})
    assert_reply(ref, :ok, _)

    assert_push("agent_event", %{"type" => "proposal", "proposal_id" => proposal_id})

    assert_push("agent_event", %{
      "type" => "session_budget_exhausted",
      "session_id" => ^session_id,
      "limit" => "spend_cap",
      "message" => message,
      "proposal" => %{"proposal_id" => ^proposal_id}
    })

    assert message =~ "new planning session"
    refute_push("agent_event", %{"type" => "agent_unavailable"}, 100)

    ref = push(socket, "send_message", %{"text" => "Again"})
    assert_reply(ref, :error, %{reason: "session_budget_exhausted"})
    cancel!(socket)
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

  test "the Member saves a dictated recipe through the channel", %{household: h} do
    leek = ingredient!("Fictitious dictated leek")

    configure_agent([
      {:tool_calls,
       [
         {"create_recipe",
          %{
            "name" => "Fictitious family leek pie",
            "servings" => 4,
            "slots" => ["dinner"],
            "origin" => "user_created",
            "ingredients" => [%{"ingredient" => leek.name, "quantity" => 300, "unit" => "g"}],
            "steps" => ["Bake."]
          }}
       ]},
      {:text, "Here is your recipe; press save to keep it."}
    ])

    socket = join!(h, h.owner)

    ref = push(socket, "save_recipe", %{"recipe_id" => Ecto.UUID.generate()})
    assert_reply(ref, :error, %{reason: "no_active_session"})

    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, _)
    ref = push(socket, "give_consent", %{})
    assert_reply(ref, :ok, _)
    ref = push(socket, "send_message", %{"text" => "My family leek pie: ..."})
    assert_reply(ref, :ok, _)

    assert_push("agent_event", %{
      "type" => "recipe_draft",
      "origin" => "user_created",
      "recipe_id" => recipe_id
    })

    assert_push("agent_event", %{"type" => "turn_completed"})

    ref = push(socket, "save_recipe", %{})
    assert_reply(ref, :error, %{reason: "invalid_payload"})

    ref = push(socket, "save_recipe", %{"recipe_id" => recipe_id})
    assert_reply(ref, :ok, %{recipe_id: ^recipe_id, origin: "user_created"})
    assert_push("agent_event", %{"type" => "recipe_saved", "recipe_id" => ^recipe_id})

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

  # The socket drops; the session stays for its absence grace.
  defp drop!(socket) do
    Process.unlink(socket.channel_pid)
    ref = Process.monitor(socket.channel_pid)
    close(socket)
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  test "a Member who reconnects resumes the session and reads its Proposal", %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, %{session_id: session_id})
    ref = push(socket, "give_consent", %{})
    assert_reply(ref, :ok, _)
    ref = push(socket, "send_message", %{"text" => "Plan dinner"})
    assert_reply(ref, :ok, _)
    assert_push("agent_event", %{"type" => "proposal", "proposal_id" => proposal_id})
    assert_push("agent_event", %{"type" => "turn_completed"})

    drop!(socket)

    socket = join!(h, h.owner)
    ref = push(socket, "resume_session", %{})

    assert_reply(ref, :ok, %{
      session_id: ^session_id,
      proposal: %{"proposal_id" => ^proposal_id, "status" => "valid"}
    })

    # The resumed socket drives the session again.
    ref = push(socket, "give_consent", %{})
    assert_reply(ref, :ok, _)
    cancel!(socket)
  end

  test "resuming without a Planning Session is refused", %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "resume_session", %{})
    assert_reply(ref, :error, %{reason: "no_session"})
  end

  test "resuming a session that does not answer is refused as busy", %{household: h} do
    socket = join!(h, h.owner)
    ref = push(socket, "start_session", @range)
    assert_reply(ref, :ok, _)
    pid = Session.whereis(h.account_id)
    _ = Session.current_proposal(pid)

    drop!(socket)
    :ok = :sys.suspend(pid)

    socket = join!(h, h.owner)
    ref = push(socket, "resume_session", %{})
    # The session's default answer timeout is 5 seconds.
    assert_reply(ref, :error, %{reason: "session_busy"}, 6_000)
    assert Session.whereis(h.account_id) == pid

    :ok = :sys.resume(pid)
    cancel!(socket)
  end

  test "cancel_session frees a slot held by a session waiting for recovery", %{household: h} do
    member = member!(h)
    member_socket = join!(h, member)
    ref = push(member_socket, "start_session", @range)
    assert_reply(ref, :ok, _)

    # A server restart: no process runs the session any more.
    pid = Session.whereis(h.account_id)
    monitor = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(MealPlannerApi.PlanningAgent.SessionSupervisor, pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}

    owner_socket = join!(h, h.owner)
    cancel!(owner_socket)

    ref = push(owner_socket, "start_session", @range)
    assert_reply(ref, :ok, _)
    cancel!(owner_socket)
  end
end
