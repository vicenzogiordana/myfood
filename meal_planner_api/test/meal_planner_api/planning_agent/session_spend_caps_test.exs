defmodule MealPlannerApi.PlanningAgent.SessionSpendCapsTest do
  @moduledoc """
  The paid-service spend cap and cumulative token cap bound OpenAI calls for
  the whole Planning Session (spec #93, user stories 102 and 103, scoped per
  Planning Session by the product owner): neither Stop nor a new Member
  message resets them.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.PlanningAgent.Model.OpenAIResponses
  alias MealPlannerApi.PlanningAgent.Session

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    member = member!(household)
    consent!(household, member)

    :persistent_term.put({__MODULE__, :observer}, self())
    on_exit(fn -> :persistent_term.erase({__MODULE__, :observer}) end)

    %{household: household, member: member}
  end

  defp start!(household, member, model) do
    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(session_attrs(household, member, {@monday, @tuesday}),
        model: model,
        subscriber: self()
      )

    {session_id, pid}
  end

  defp actor(member), do: %{membership_id: member.membership_id, owner?: false}

  # Every provider call hangs, so each turn ends by Stop with its worst-case
  # reservation (~400_000 micro-USD) kept as spent. One reservation fits the
  # cap; a second one in the same Planning Session does not.
  defp hanging_provider(spend_cap_micros, token_cap) do
    {OpenAIResponses,
     api_key: "test-key",
     spend_cap_micros: spend_cap_micros,
     token_cap: token_cap,
     input_price_micros_per_mtok: 1_000_000,
     output_price_micros_per_mtok: 4_000_000,
     max_output_tokens: 100_000,
     req_options: [
       plug: fn conn ->
         send(:persistent_term.get({__MODULE__, :observer}), :provider_called)
         Process.sleep(:infinity)
         conn
       end
     ]}
  end

  test "Stop and a new message never reset the spend cap", %{household: h, member: member} do
    {session_id, pid} =
      start!(h, member, hanging_provider(600_000, 100_000_000))

    :ok = Session.send_message(pid, "Plan")
    assert_receive :provider_called, 2_000
    assert :ok = Session.stop(pid, actor(member))

    :ok = Session.send_message(pid, "Plan again")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "agent_unavailable", "reason" => "spend_cap_reached"}},
                   2_000

    refute_received :provider_called
  end

  test "Stop and a new message never reset the token cap", %{household: h, member: member} do
    {session_id, pid} =
      start!(h, member, hanging_provider(100_000_000, 150_000))

    :ok = Session.send_message(pid, "Plan")
    assert_receive :provider_called, 2_000
    assert :ok = Session.stop(pid, actor(member))

    :ok = Session.send_message(pid, "Plan again")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "agent_unavailable", "reason" => "token_cap_reached"}},
                   2_000

    refute_received :provider_called
  end
end
