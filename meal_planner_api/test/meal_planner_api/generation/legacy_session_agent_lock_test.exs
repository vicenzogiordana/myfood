defmodule MealPlannerApi.Generation.LegacySessionAgentLockTest do
  @moduledoc """
  The legacy planning session path against the agent's Household lock
  (issue #119, spec #93: one Planning Session per Household). Legacy
  sessions keep their per-range rule among themselves, but none starts
  while an agent Planning Session holds the Household.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Generation.PlanningSessionServer
  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    %{household: household, owner: household.owner, member: member!(household)}
  end

  defp legacy_start(household, member, range) do
    server =
      start_supervised!(
        {PlanningSessionServer,
         account_id: household.account_id,
         owner_user_id: member.user_id,
         owner_membership_id: member.membership_id,
         check_account_eligible_fn: fn _ -> true end},
        id: make_ref()
      )

    PlanningSessionServer.start_session(
      server,
      household.account_id,
      member.user_id,
      member.membership_id,
      range
    )
  end

  defp active_sessions(household) do
    Repo.all(
      from(s in PlanningSession,
        where: s.account_id == ^household.account_id and s.status == :active
      )
    )
  end

  test "a legacy session cannot start while an agent session holds the Household",
       %{household: h, owner: owner, member: member} do
    {:ok, %{session_id: agent_id}} =
      Session.start(session_attrs(h, member, {@monday, @tuesday}),
        model: {Scripted, []},
        subscriber: self()
      )

    # A disjoint range is refused too: the agent holds the whole Household.
    assert {:error, :session_already_active} =
             legacy_start(h, owner, {~D[2026-12-01], ~D[2026-12-02]})

    assert [%PlanningSession{id: ^agent_id}] = active_sessions(h)
  end

  test "a legacy session starts once the agent session ended",
       %{household: h, owner: owner, member: member} do
    {:ok, %{pid: pid}} =
      Session.start(session_attrs(h, member, {@monday, @tuesday}),
        model: {Scripted, []},
        subscriber: self()
      )

    :ok = Session.cancel(pid, %{membership_id: member.membership_id, owner?: false})

    assert {:ok, %{session_id: legacy_id}} = legacy_start(h, owner, {@monday, @tuesday})
    assert [%PlanningSession{id: ^legacy_id}] = active_sessions(h)
  end

  test "legacy sessions keep their per-range rule among themselves",
       %{household: h, owner: owner, member: member} do
    assert {:ok, _} = legacy_start(h, owner, {@monday, @tuesday})
    assert {:ok, _} = legacy_start(h, member, {~D[2026-12-01], ~D[2026-12-02]})
    assert {:error, :overlapping_range} = legacy_start(h, member, {@tuesday, @tuesday})
    assert length(active_sessions(h)) == 2
  end
end
