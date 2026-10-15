defmodule MealPlannerApi.PlanningAgent.SessionRecoveryTest do
  @moduledoc """
  Restart recovery through the planning agent session module (spec #93,
  user stories 87, 88 and 101, issue #107): the Workspace is kept in
  recoverable storage, so a server restart within the grace restores the
  Planning Session when its Member returns; uncertain work is reconciled,
  never replayed; there is no unattended restart; neither grace nor limits
  reset; a Member whose access was revoked cannot resume.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Planning.{
    PlanningAgentRecovery,
    PlanningSession,
    ScheduledMeal
  }

  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]
  @sessions MealPlannerApi.PlanningAgent.SessionSupervisor

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    member = member!(household)
    consent!(household, member)

    rice = ingredient!("Fictitious rice")
    recipe!("Gamma rice bowl", [rice])

    %{household: household, owner: household.owner, member: member}
  end

  # The Member's connection: it forwards every event to the test and can be
  # closed like a dropped socket.
  defp socket! do
    test_pid = self()
    spawn(fn -> forward(test_pid) end)
  end

  defp forward(test_pid) do
    receive do
      :close ->
        :ok

      message ->
        send(test_pid, {:socket, message})
        forward(test_pid)
    end
  end

  defp close(socket) do
    ref = Process.monitor(socket)
    send(socket, :close)
    assert_receive {:DOWN, ^ref, :process, ^socket, _}
  end

  # A call returns once the session handled everything sent before it.
  defp settle(pid), do: _ = Session.current_proposal(pid)

  defp start!(household, member, script, opts) do
    attrs = session_attrs(household, member, {@monday, @tuesday})

    session_opts =
      Keyword.merge(
        [model: {Scripted, script: script, notify: self()}, optimizer: {FakeOptimizer, []}],
        opts
      )

    {:ok, %{session_id: session_id, pid: pid}} = Session.start(attrs, session_opts)
    {session_id, pid}
  end

  defp resume(household, member, script \\ [], opts \\ []) do
    Session.resume(
      session_attrs(household, member, {@monday, @tuesday}),
      Keyword.merge(
        [
          model: {Scripted, script: script, notify: self()},
          optimizer: {FakeOptimizer, []},
          subscriber: self()
        ],
        opts
      )
    )
  end

  # A graceful server restart: the supervisor shuts the session down.
  defp restart!(pid) do
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(@sessions, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  # A hard crash: the session gets no chance to clean up.
  defp crash!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp session_row(session_id), do: Repo.get!(PlanningSession, session_id)

  defp snapshots(session_id),
    do: Repo.all(from(r in PlanningAgentRecovery, where: r.session_id == ^session_id))

  defp planned_meals(household),
    do: Repo.all(from(m in ScheduledMeal, where: m.account_id == ^household.account_id))

  @proposal_script [
    {:tool_calls, [{"run_optimizer", %{}}]},
    {:tool_calls, [{"present_proposal", %{}}]},
    {:text, "Here is your plan"}
  ]

  defp propose!(pid, session_id) do
    :ok = Session.send_message(pid, "Plan")

    assert_receive {:socket,
                    {:planning_agent_event, ^session_id,
                     %{"type" => "proposal", "proposal_id" => proposal_id}}},
                   2_000

    assert_receive {:socket, {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}},
                   2_000

    proposal_id
  end

  describe "restart within the grace" do
    test "restores the Planning Session with its Workspace and Proposal",
         %{household: h, member: member} do
      socket = socket!()
      {session_id, pid} = start!(h, member, @proposal_script, subscriber: socket)
      proposal_id = propose!(pid, session_id)

      restart!(pid)

      # No unattended restart: nothing runs until the Member returns, and
      # the Household's slot stays held meanwhile.
      assert Session.whereis(h.account_id) == nil
      assert %PlanningSession{status: :active} = session_row(session_id)

      assert {:error, :session_already_active} =
               Session.start(session_attrs(h, member, {@monday, @tuesday}),
                 model: {Scripted, []},
                 subscriber: self()
               )

      assert {:ok, %{session_id: ^session_id, pid: recovered, proposal: proposal}} =
               resume(h, member)

      assert recovered != pid
      assert Session.whereis(h.account_id) == recovered
      assert %{"proposal_id" => ^proposal_id, "status" => "valid"} = proposal
      assert Session.current_proposal(recovered) == proposal

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "session_recovered", "interrupted" => false}}

      assert {:ok, %{meals_count: 4}} =
               Session.confirm(h.account_id, member.membership_id, proposal_id)

      assert length(planned_meals(h)) == 4
      assert snapshots(session_id) == []
    end

    test "survives a hard crash, because the Workspace is kept as it changes",
         %{household: h, member: member} do
      socket = socket!()
      {session_id, pid} = start!(h, member, @proposal_script, subscriber: socket)
      proposal_id = propose!(pid, session_id)

      # Killed between messages: a kill during a query would take the test's
      # shared database connection with it.
      settle(pid)
      crash!(pid)

      assert {:ok, %{proposal: %{"proposal_id" => ^proposal_id}}} = resume(h, member)
    end

    test "an interrupted request is reconciled, never replayed", %{household: h, member: member} do
      test_pid = self()

      blocked = fn _request ->
        send(test_pid, :model_blocked)
        Process.sleep(:infinity)
      end

      {session_id, pid} = start!(h, member, [blocked], subscriber: self())
      :ok = Session.send_message(pid, "Plan")
      assert_receive {:scripted_model_request, _}, 2_000
      assert_receive :model_blocked, 2_000

      restart!(pid)

      assert {:ok, %{pid: recovered}} = resume(h, member, [{:text, "Ask me again"}])

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "session_recovered", "interrupted" => true}}

      # Recovery itself calls nothing: the interrupted request stays undone.
      refute_receive {:scripted_model_request, _}, 300

      :ok = Session.send_message(recovered, "Plan again")
      assert_receive {:scripted_model_request, request}, 2_000

      assert Enum.any?(request.messages, fn message ->
               message.role == :user and String.contains?(message.content, "[Session recovered]")
             end)

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Ask me again"}},
                     2_000
    end

    test "limits are not reset by a restart", %{household: h, member: member} do
      {session_id, pid} =
        start!(h, member, [{:text, "One"}], subscriber: self(), max_iterations: 1)

      :ok = Session.send_message(pid, "Plan")
      assert_receive {:scripted_model_request, _}, 2_000
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}, 2_000

      restart!(pid)

      assert {:ok, %{pid: recovered}} = resume(h, member, [{:text, "Two"}], max_iterations: 10)
      :ok = Session.send_message(recovered, "More")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "iterations"}},
                     2_000

      refute_received {:scripted_model_request, _}
    end

    test "the grace is not reset by a restart", %{household: h, member: member} do
      socket = socket!()
      {session_id, pid} = start!(h, member, [], subscriber: socket)
      close(socket)
      settle(pid)
      deadline = session_row(session_id).lease_expires_at

      restart!(pid)
      assert session_row(session_id).lease_expires_at == deadline

      # The grace passes before the Member returns.
      Repo.update_all(from(s in PlanningSession, where: s.id == ^session_id),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert {:error, :no_session} = resume(h, member)
      assert %PlanningSession{status: :expired} = session_row(session_id)
      assert snapshots(session_id) == []
      assert Session.whereis(h.account_id) == nil
    end
  end

  describe "access to a recovered session" do
    test "a Member removed from the Household cannot resume it", %{household: h, member: member} do
      socket = socket!()
      {session_id, pid} = start!(h, member, @proposal_script, subscriber: socket)
      _proposal_id = propose!(pid, session_id)
      restart!(pid)

      remove_member!(member)

      assert {:error, :forbidden} = resume(h, member)
      assert Session.whereis(h.account_id) == nil
    end

    test "only the session's Member recovers it", %{household: h, owner: owner, member: member} do
      {_session_id, pid} = start!(h, member, [], subscriber: self())
      restart!(pid)

      assert {:error, :forbidden} = resume(h, owner)
      assert Session.whereis(h.account_id) == nil
    end

    test "the Owner cancels a session waiting for recovery and frees the slot",
         %{household: h, owner: owner, member: member} do
      {session_id, pid} = start!(h, member, [], subscriber: self())
      restart!(pid)

      peer = member!(h)

      assert {:error, :forbidden} =
               Session.cancel_recoverable(h.account_id, %{
                 membership_id: peer.membership_id,
                 owner?: false
               })

      assert :ok =
               Session.cancel_recoverable(h.account_id, %{
                 membership_id: owner.membership_id,
                 owner?: true
               })

      assert %PlanningSession{status: :cancelled} = session_row(session_id)
      assert snapshots(session_id) == []
      assert {:error, :no_session} = resume(h, member)

      assert {:ok, _} =
               Session.start(session_attrs(h, owner, {@monday, @tuesday}),
                 model: {Scripted, []},
                 subscriber: self()
               )
    end
  end
end
