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
  alias MealPlannerApi.Repo
  alias MealPlannerApiWeb.{PlanningAgentChannel, UserSocket}

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
end
