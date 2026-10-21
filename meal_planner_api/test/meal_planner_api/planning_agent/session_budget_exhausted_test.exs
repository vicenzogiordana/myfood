defmodule MealPlannerApi.PlanningAgent.SessionBudgetExhaustedTest do
  @moduledoc """
  An exhausted cap ends the agent's part of a Planning Session gracefully
  (issue #154, spec #93): the Member gets `session_budget_exhausted` with a
  code-rendered message and the latest Proposal, and no further turn that
  could only be refused.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session

  @monday ~D[2026-11-02]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)
    recipe!("Fictitious soup", [ingredient!("Fictitious leek")])

    %{household: household}
  end

  defp start!(household, script) do
    attrs = session_attrs(household, household.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, []},
        subscriber: self()
      )

    {session_id, pid}
  end

  defp model_requests(acc \\ 0) do
    receive do
      {:scripted_model_request, _} -> model_requests(acc + 1)
    after
      100 -> acc
    end
  end

  test "the spend cap ends the session with the latest Proposal, rendered by code",
       %{household: h} do
    script = [
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:text, "Here is your plan."},
      {:error, :spend_cap_reached}
    ]

    {session_id, pid} = start!(h, script)

    :ok = Session.send_message(pid, "Plan Monday")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "proposal", "proposal_id" => proposal_id}}

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

    :ok = Session.send_message(pid, "Make it cheaper")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "session_budget_exhausted", "limit" => "spend_cap"} = event}

    assert event["message"] =~ "confirm it"
    assert event["message"] =~ "new planning session"
    assert %{"proposal_id" => ^proposal_id, "meals" => [_ | _]} = event["proposal"]

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "run_finished", "outcome" => "partial"}}

    refute_received {:planning_agent_event, ^session_id, %{"type" => "agent_unavailable"}}
    assert model_requests() == 4

    # No turn that could only be refused: the Member is told why again.
    assert {:error, :session_budget_exhausted} = Session.send_message(pid, "Try again")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "session_budget_exhausted", "proposal" => %{}}}

    assert model_requests() == 0

    # The Proposal can still be confirmed.
    assert {:ok, %{meals_count: 2}} =
             Session.confirm(h.account_id, h.owner.membership_id, proposal_id)
  end

  # Issue #151: a revalidation conflict in an exhausted session voids the
  # Proposal but starts no paid turn to correct it; with nothing left to act
  # on, the session ends like an exhausted one without a Proposal.
  test "a revalidation conflict after the spend cap starts no turn and ends the session",
       %{household: h} do
    recipe!("Fictitious stew", [ingredient!("Fictitious beef", [:contains_meat])])

    script = [
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:text, "Here is your plan."},
      {:error, :spend_cap_reached}
    ]

    attrs = session_attrs(h, h.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, result: pick("Fictitious stew")},
        subscriber: self()
      )

    ref = Process.monitor(pid)

    :ok = Session.send_message(pid, "Plan Monday")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "proposal", "proposal_id" => proposal_id}}

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
    :ok = Session.send_message(pid, "Make it cheaper")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "session_budget_exhausted", "limit" => "spend_cap"}}

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}
    assert model_requests() == 4
    flush_progress(session_id)

    diet!(h.owner, :vegetarian)

    assert {:error, :revalidation_conflict} =
             Session.confirm(h.account_id, h.owner.membership_id, proposal_id)

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "proposal_invalidated", "proposal_id" => ^proposal_id}}

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "session_budget_exhausted", "proposal" => nil} = event}

    assert event["message"] =~ "new planning session"
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    refute_received {:planning_agent_event, ^session_id, %{"type" => "progress"}}
    assert model_requests() == 0
  end

  # The optimizer picks the candidate labelled `name` for every day and slot.
  defp pick(name) do
    fn payload ->
      meals =
        for day <- payload["days"], slot <- payload["slots"] do
          %{"recipe_id" => id} =
            Enum.find(payload["candidates_by_slot"][slot], &(&1["label"] == name))

          %{"day" => day, "slot" => slot, "recipe_id" => id}
        end

      {:ok, %{"meals" => meals}}
    end
  end

  defp flush_progress(session_id) do
    receive do
      {:planning_agent_event, ^session_id, %{"type" => "progress"}} -> flush_progress(session_id)
    after
      0 -> :ok
    end
  end

  test "the token cap without a Proposal ends the session and frees the Household",
       %{household: h} do
    {session_id, pid} = start!(h, [{:error, :token_cap_reached}])
    ref = Process.monitor(pid)

    :ok = Session.send_message(pid, "Plan Monday")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "session_budget_exhausted", "limit" => "token_cap"} = event}

    assert event["proposal"] == nil
    assert event["message"] =~ "new planning session"
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    # A new Planning Session can start right away.
    {_new_session_id, _pid} = start!(h, [])
  end
end
