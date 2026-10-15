defmodule MealPlannerApi.PlanningAgent.SessionStopCancelTest do
  @moduledoc """
  Stop and Cancel through the planning agent session module (spec #93, user
  stories 84, 84a, 84b, 85): in-flight work halted within 5 s, the optimizer
  OS process gone, and late results discarded.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Optimizer.Port, as: PortOptimizer
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]
  @stop_budget_ms 5_000
  @hanging_optimizer Path.expand("../../support/fixtures/hanging_optimizer.py", __DIR__)

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

  defp start!(household, member, script, opts \\ []) do
    attrs = session_attrs(household, member, {@monday, @tuesday})

    session_opts =
      Keyword.merge(
        [
          model: {Scripted, script: script, notify: self()},
          optimizer: {FakeOptimizer, []},
          subscriber: self()
        ],
        opts
      )

    {:ok, %{session_id: session_id, pid: pid}} = Session.start(attrs, session_opts)
    {session_id, pid}
  end

  defp actor(member, owner? \\ false), do: %{membership_id: member.membership_id, owner?: owner?}

  # A model step that tells the test it is running, then never answers.
  defp blocking_step(test_pid) do
    fn _request ->
      send(test_pid, :model_blocked)
      Process.sleep(:infinity)
    end
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  defp active_sessions(household) do
    Repo.all(
      from(s in PlanningSession,
        where: s.account_id == ^household.account_id and s.status == :active
      )
    )
  end

  # Signal 0 only checks that the OS process exists.
  defp os_alive?(os_pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  # Runs the real port optimizer over a stand-in that ignores stdin and
  # never answers, like a busy solver; its OS pid is reported to the test.
  defp hanging_optimizer do
    test_pid = self()

    {PortOptimizer,
     python_executable: System.find_executable("python3"),
     script_path: @hanging_optimizer,
     timeout_ms: 60_000,
     on_os_process: fn
       {:started, os_pid} -> send(test_pid, {:optimizer_os_pid, os_pid})
       _event -> :ok
     end}
  end

  describe "stop" do
    test "halts the running turn within 5 s and keeps the session, Workspace and last valid Proposal",
         %{household: h, member: member} do
      script = [
        {:tool_calls, [{"run_optimizer", %{}}]},
        {:tool_calls, [{"present_proposal", %{}}]},
        blocking_step(self()),
        # After Stop the Workspace still holds the optimizer draft, so the
        # next turn can present it again without re-running the optimizer.
        {:tool_calls, [{"present_proposal", %{}}]},
        {:text, "Here it is again"}
      ]

      {session_id, pid} = start!(h, member, script)
      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal", "proposal_id" => proposal_id}},
                     2_000

      assert_receive :model_blocked, 2_000

      {result, elapsed} = timed(fn -> Session.stop(pid, actor(member)) end)
      assert result == :ok
      assert elapsed < @stop_budget_ms
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "stopped"}}

      assert Session.whereis(h.account_id) == pid
      assert [%PlanningSession{id: ^session_id}] = active_sessions(h)
      assert %{"proposal_id" => ^proposal_id} = Session.current_proposal(pid)

      :ok = Session.send_message(pid, "Show it again")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal", "status" => "valid"}},
                     2_000

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}, 2_000
    end

    test "results of a stopped turn arriving late are discarded",
         %{household: h, member: member} do
      test_pid = self()

      slow = fn _request ->
        send(test_pid, :model_blocked)
        Process.sleep(300)
        {:text, "late answer"}
      end

      {session_id, pid} = start!(h, member, [slow])
      :ok = Session.send_message(pid, "Plan")
      assert_receive :model_blocked, 2_000

      assert :ok = Session.stop(pid, actor(member))
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "stopped"}}

      refute_receive {:planning_agent_event, ^session_id, %{"type" => "assistant_message"}}, 600
      refute_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
      assert Session.current_proposal(pid) == nil
    end

    test "a stopped session accepts a new message", %{household: h, member: member} do
      {session_id, pid} = start!(h, member, [blocking_step(self()), {:text, "Back again"}])
      :ok = Session.send_message(pid, "Plan")
      assert_receive :model_blocked, 2_000

      assert {:error, :busy} = Session.send_message(pid, "Another")
      assert :ok = Session.stop(pid, actor(member))

      :ok = Session.send_message(pid, "Another")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Back again"}},
                     2_000
    end

    test "only the session's Member may Stop; the Owner's extra power is Cancel only",
         %{household: h, owner: owner, member: member} do
      peer = member!(h)
      {_session_id, pid} = start!(h, member, [])

      assert {:error, :forbidden} = Session.stop(pid, actor(peer))
      assert {:error, :forbidden} = Session.stop(pid, actor(owner, true))
      assert :ok = Session.stop(pid, actor(member))
    end

    test "the optimizer OS process is gone when Stop returns", %{household: h, member: member} do
      script = [{:tool_calls, [{"run_optimizer", %{}}]}, {:text, "never reached"}]
      {session_id, pid} = start!(h, member, script, optimizer: hanging_optimizer())

      :ok = Session.send_message(pid, "Plan")
      assert_receive {:optimizer_os_pid, os_pid}, 5_000
      assert os_alive?(os_pid)

      {result, elapsed} = timed(fn -> Session.stop(pid, actor(member)) end)
      assert result == :ok
      assert elapsed < @stop_budget_ms
      refute os_alive?(os_pid)

      refute_receive {:planning_agent_event, ^session_id, %{"type" => "optimizer_failed"}}, 200
      assert Session.whereis(h.account_id) == pid
    end
  end

  describe "cancel" do
    test "discards the Workspace, frees the slot and kills the optimizer OS process first",
         %{household: h, owner: owner, member: member} do
      script = [{:tool_calls, [{"run_optimizer", %{}}]}, {:text, "never reached"}]
      {session_id, pid} = start!(h, member, script, optimizer: hanging_optimizer())
      ref = Process.monitor(pid)

      :ok = Session.send_message(pid, "Plan")
      assert_receive {:optimizer_os_pid, os_pid}, 5_000

      {result, elapsed} = timed(fn -> Session.cancel(pid, actor(owner, true)) end)
      assert result == :ok
      assert elapsed < @stop_budget_ms
      # By the time the slot is free the old work can no longer act.
      refute os_alive?(os_pid)
      assert active_sessions(h) == []

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "session_cancelled"}}
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      refute_receive {:planning_agent_event, ^session_id, %{"type" => "optimizer_failed"}}, 200

      assert {:ok, %{pid: new_pid}} =
               Session.start(session_attrs(h, owner, {@monday, @tuesday}),
                 model: {Scripted, []},
                 subscriber: self()
               )

      assert Session.current_proposal(new_pid) == nil
    end

    test "a non-Owner peer cannot Cancel another Member's session",
         %{household: h, member: member} do
      peer = member!(h)
      {_session_id, pid} = start!(h, member, [])

      assert {:error, :forbidden} = Session.cancel(pid, actor(peer))
      assert Session.whereis(h.account_id) == pid
    end
  end
end
