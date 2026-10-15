defmodule MealPlannerApi.PlanningAgent.SessionGraceTest do
  @moduledoc """
  Absence grace through the planning agent session module (spec #93, user
  stories 86 and 89, issue #107): leaving keeps the Planning Session, its
  Workspace, the last Proposal and the Household's slot for the grace; no
  model call or save happens while the Member is absent; expiry discards the
  Workspace and frees the slot.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Planning.{PlanningSession, ScheduledMeal}
  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]
  @grace_ms 15 * 60 * 1000

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

  # The Member's connection: it subscribes to the session, forwards every
  # event to the test, and can be closed like a dropped socket.
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

  defp resume(household, member, opts \\ []),
    do:
      Session.resume(
        session_attrs(household, member, {@monday, @tuesday}),
        Keyword.put_new(opts, :subscriber, self())
      )

  defp session_row(session_id), do: Repo.get!(PlanningSession, session_id)

  defp planned_meals(household),
    do: Repo.all(from(m in ScheduledMeal, where: m.account_id == ^household.account_id))

  @proposal_script [
    {:tool_calls, [{"run_optimizer", %{}}]},
    {:tool_calls, [{"present_proposal", %{}}]},
    {:text, "Here is your plan"}
  ]

  # Runs one request to a shown Proposal through the Member's socket.
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

  describe "absence" do
    test "a Member who reconnects within the grace finds the Workspace and Proposal",
         %{household: h, member: member} do
      socket = socket!()
      {session_id, pid} = start!(h, member, @proposal_script, subscriber: socket)
      proposal_id = propose!(pid, session_id)

      close(socket)
      settle(pid)

      # The session, its slot and its Proposal survive the disconnect, and
      # the slot is held for the whole grace.
      assert Session.whereis(h.account_id) == pid
      assert %PlanningSession{status: :active} = row = session_row(session_id)
      remaining_ms = DateTime.diff(row.lease_expires_at, DateTime.utc_now(), :millisecond)
      assert remaining_ms > @grace_ms - 60_000 and remaining_ms <= @grace_ms

      assert {:ok, %{session_id: ^session_id, pid: ^pid, proposal: proposal}} =
               resume(h, member)

      assert %{"proposal_id" => ^proposal_id, "status" => "valid"} = proposal

      assert {:ok, %{meals_count: 4}} =
               Session.confirm(h.account_id, member.membership_id, proposal_id)
    end

    test "no model call starts while the Member is absent; the call in flight may finish",
         %{household: h, member: member} do
      test_pid = self()

      in_flight = fn _request ->
        send(test_pid, {:in_flight, self()})
        receive(do: (:finish -> {:tool_calls, [{"run_optimizer", %{}}]}))
      end

      socket = socket!()

      {session_id, pid} =
        start!(h, member, [in_flight, {:text, "Welcome back"}], subscriber: socket)

      :ok = Session.send_message(pid, "Plan")
      assert_receive {:scripted_model_request, _first}, 2_000
      assert_receive {:in_flight, call_pid}, 2_000

      close(socket)
      settle(pid)
      send(call_pid, :finish)

      # The finished call's tools ran, but the next model call never starts.
      refute_receive {:scripted_model_request, _second}, 500

      assert {:ok, %{pid: ^pid}} = resume(h, member)

      # The interrupted run is over, so the Member can ask again.
      assert :ok = Session.send_message(pid, "I am back")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Welcome back"}},
                     2_000
    end

    test "nothing is saved while the Member is absent", %{household: h, member: member} do
      socket = socket!()
      {session_id, pid} = start!(h, member, @proposal_script, subscriber: socket)
      proposal_id = propose!(pid, session_id)

      close(socket)
      settle(pid)

      assert {:error, :member_absent} =
               Session.confirm(h.account_id, member.membership_id, proposal_id)

      assert planned_meals(h) == []
      assert Session.whereis(h.account_id) == pid
    end

    test "the grace expiry discards the Workspace and frees the Household's slot",
         %{household: h, owner: owner, member: member} do
      socket = socket!()
      {session_id, pid} = start!(h, member, @proposal_script, subscriber: socket, grace_ms: 150)
      _proposal_id = propose!(pid, session_id)
      ref = Process.monitor(pid)

      close(socket)
      settle(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert %PlanningSession{status: :expired} = session_row(session_id)
      assert Session.whereis(h.account_id) == nil
      assert {:error, :no_session} = resume(h, member)

      assert {:ok, _} =
               Session.start(session_attrs(h, owner, {@monday, @tuesday}),
                 model: {Scripted, []},
                 subscriber: self()
               )
    end

    test "returning within the grace keeps the session past its first deadline",
         %{household: h, member: member} do
      socket = socket!()
      {session_id, pid} = start!(h, member, [], subscriber: socket, grace_ms: 300)

      close(socket)
      settle(pid)
      assert {:ok, %{session_id: ^session_id}} = resume(h, member)

      Process.sleep(500)
      assert Session.whereis(h.account_id) == pid
      assert %PlanningSession{status: :active} = session_row(session_id)
    end

    test "only the session's Member resumes it", %{household: h, owner: owner, member: member} do
      socket = socket!()
      {_session_id, pid} = start!(h, member, [], subscriber: socket)
      close(socket)
      settle(pid)

      assert {:error, :forbidden} = resume(h, owner)
      assert Session.whereis(h.account_id) == pid
    end

    test "a Member removed from the Household cannot resume", %{household: h, member: member} do
      socket = socket!()
      {_session_id, pid} = start!(h, member, [], subscriber: socket)
      close(socket)
      settle(pid)

      remove_member!(member)

      assert {:error, :forbidden} = resume(h, member)
      assert Session.whereis(h.account_id) == pid
    end
  end

  describe "idle expiry" do
    test "a connected Member who does nothing for the idle time loses the session and the slot",
         %{household: h, owner: owner, member: member} do
      {session_id, pid} = start!(h, member, [], subscriber: self(), idle_ms: 150)
      ref = Process.monitor(pid)

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert %PlanningSession{status: :expired} = session_row(session_id)
      assert Session.whereis(h.account_id) == nil
      assert {:error, :no_session} = resume(h, member)

      assert {:ok, _} =
               Session.start(session_attrs(h, owner, {@monday, @tuesday}),
                 model: {Scripted, []},
                 subscriber: self()
               )
    end

    test "every Member action restarts the idle time", %{household: h, member: member} do
      script = for n <- 1..3, do: {:text, "Answer #{n}"}
      {session_id, pid} = start!(h, member, script, subscriber: self(), idle_ms: 400)

      for n <- 1..3 do
        Process.sleep(250)
        assert :ok = Session.send_message(pid, "Message #{n}")
        text = "Answer #{n}"

        assert_receive {:planning_agent_event, ^session_id,
                        %{"type" => "assistant_message", "text" => ^text}},
                       2_000
      end

      assert Session.whereis(h.account_id) == pid
      assert %PlanningSession{status: :active} = session_row(session_id)
    end

    test "a running turn is never cut by the idle time; it restarts when the turn ends",
         %{household: h, member: member} do
      test_pid = self()

      slow = fn _request ->
        send(test_pid, {:in_flight, self()})
        receive(do: (:finish -> {:text, "Done"}))
      end

      {session_id, pid} = start!(h, member, [slow], subscriber: self(), idle_ms: 150)
      ref = Process.monitor(pid)

      :ok = Session.send_message(pid, "Plan")
      assert_receive {:in_flight, call_pid}, 2_000

      refute_receive {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}, 400
      assert Session.whereis(h.account_id) == pid

      send(call_pid, :finish)

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Done"}},
                     2_000

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert %PlanningSession{status: :expired} = session_row(session_id)
    end
  end
end
