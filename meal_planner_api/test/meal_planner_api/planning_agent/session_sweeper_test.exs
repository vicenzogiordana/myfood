defmodule MealPlannerApi.PlanningAgent.SessionSweeperTest do
  @moduledoc """
  The planning session Sweeper against rows owned by agent Planning
  Sessions (issue #119): it never expires a live session's lock, and it
  never leaves a stale one behind.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Generation.PlanningSession.Sweeper
  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]
  @sweeps_ms 300

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    :ok = Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "planning:#{household.account_id}")
    %{household: household, owner: household.owner, member: member!(household)}
  end

  defp start!(household, member, opts \\ []) do
    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(
        session_attrs(household, member, {@monday, @tuesday}),
        Keyword.merge([model: {Scripted, []}, subscriber: self()], opts)
      )

    {session_id, pid}
  end

  defp start_sweeper!,
    do: start_supervised!({Sweeper, interval: 50, name: :agent_lock_sweeper}, id: :sweeper)

  defp lapse_lease!(session_id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    {1, _} = Repo.update_all(lock_row(session_id), set: [lease_expires_at: past])
  end

  defp lock_row(session_id), do: from(s in PlanningSession, where: s.id == ^session_id)
  defp status(session_id), do: Repo.get!(PlanningSession, session_id).status

  defp sweep_refused(session_id),
    do:
      refute_receive(
        %{event: "session_expired", payload: %{"session_id" => ^session_id}},
        @sweeps_ms
      )

  defp swept(session_id),
    do:
      assert_receive(%{event: "session_expired", payload: %{"session_id" => ^session_id}}, 2_000)

  test "never expires the lock of a live session whose Member is connected",
       %{household: h, member: member} do
    {session_id, pid} = start!(h, member)
    start_sweeper!()

    sweep_refused(session_id)
    assert status(session_id) == :active
    assert Session.whereis(h.account_id) == pid
  end

  test "never expires the lock of a live session within its absence grace",
       %{household: h, member: member} do
    socket = spawn(fn -> receive(do: (:close -> :ok)) end)
    {session_id, pid} = start!(h, member, subscriber: socket)
    ref = Process.monitor(socket)
    send(socket, :close)
    assert_receive {:DOWN, ^ref, :process, ^socket, _}
    _ = Session.current_proposal(pid)

    start_sweeper!()

    sweep_refused(session_id)
    assert status(session_id) == :active
    assert Session.whereis(h.account_id) == pid
  end

  test "expires a recoverable session whose grace lapsed and frees the Household",
       %{household: h, owner: owner, member: member} do
    {session_id, pid} = start!(h, member)
    ref = Process.monitor(pid)

    # A server restart keeps the row and its snapshot for the grace.
    :ok = DynamicSupervisor.terminate_child(MealPlannerApi.PlanningAgent.SessionSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert {:ok, _snapshot} = PlanningRepo.fetch_recovery(session_id)

    lapse_lease!(session_id)
    start_sweeper!()

    swept(session_id)
    assert status(session_id) == :expired
    assert PlanningRepo.fetch_recovery(session_id) == :error
    assert {:error, :no_session} = Session.resume(session_attrs(h, member, {@monday, @tuesday}))
    assert {_new_id, _new_pid} = start!(h, owner)
  end

  test "a live session whose lapsed lock was swept stops and leaves no stale lock",
       %{household: h, owner: owner, member: member} do
    {session_id, pid} = start!(h, member)
    ref = Process.monitor(pid)

    lapse_lease!(session_id)
    start_sweeper!()
    swept(session_id)
    assert status(session_id) == :expired

    # Its next lease renewal finds the lock gone, so it stops spending.
    send(pid, :renew_lease)
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    assert {new_id, _new_pid} = start!(h, owner)
    sweep_refused(new_id)
    assert [%PlanningSession{id: ^new_id}] = active_rows(h)
  end

  defp active_rows(household),
    do:
      Repo.all(
        from(s in PlanningSession,
          where: s.account_id == ^household.account_id and s.status == :active
        )
      )
end
