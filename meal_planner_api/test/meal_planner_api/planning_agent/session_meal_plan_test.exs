defmodule MealPlannerApi.PlanningAgent.SessionMealPlanTest do
  @moduledoc """
  Meal Plan lookup (`get_plan`) and reuse of past weeks (`reuse_plan`)
  exercised through the session module with the scripted model and a fake
  optimizer (#105).
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session

  # Planning Range: Monday 2026-11-16 to Tuesday 2026-11-17.
  @range {~D[2026-11-16], ~D[2026-11-17]}
  # The week before last: Monday 2026-11-02 onwards.
  @past_monday ~D[2026-11-02]
  @past_tuesday ~D[2026-11-03]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    chicken = ingredient!("Fictitious chicken", [:contains_meat])
    rice = ingredient!("Fictitious rice")
    lentil = ingredient!("Fictitious lentil")

    recipes = %{
      chicken_rice: recipe!("Zeta chicken rice", [chicken, rice]),
      lentil_stew: recipe!("Alpha lentil stew", [lentil, rice]),
      rice_salad: recipe!("Beta rice salad", [rice], slots: ["lunch"])
    }

    %{household: household, recipes: recipes}
  end

  defp start!(household, script) do
    attrs = session_attrs(household, household.owner, @range)

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, notify: self()},
        subscriber: self()
      )

    {session_id, pid}
  end

  # Runs one turn of scripted tool calls followed by a final text and returns
  # the tool result of each call, in order.
  defp run_tools(household, calls) do
    script = Enum.map(calls, &{:tool_calls, [&1]}) ++ [{:text, "done"}]
    {session_id, pid} = start!(household, script)
    :ok = Session.send_message(pid, "Look at our plan")

    assert_receive {:scripted_model_request, _first}

    results =
      for _ <- calls do
        assert_receive {:scripted_model_request, %{messages: messages}}
        %{role: :tool_result, content: content} = List.last(messages)
        content
      end

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
    {session_id, results}
  end

  defp plan_week!(household, recipes) do
    scheduled_meal!(household, @past_monday, :lunch, recipes.rice_salad)
    scheduled_meal!(household, @past_monday, :dinner, recipes.lentil_stew)
    scheduled_meal!(household, @past_tuesday, :lunch, recipes.lentil_stew)
    scheduled_meal!(household, @past_tuesday, :dinner, recipes.chicken_rice)
  end

  describe "get_plan" do
    test "returns the Planned Meals of one date", %{household: h, recipes: r} do
      plan_week!(h, r)

      {_session_id, [result]} = run_tools(h, [{"get_plan", %{"from" => "2026-11-02"}}])

      assert result["meals"] == [
               %{
                 "date" => "2026-11-02",
                 "slot" => "lunch",
                 "recipe_id" => r.rice_salad.id,
                 "name" => "Beta rice salad"
               },
               %{
                 "date" => "2026-11-02",
                 "slot" => "dinner",
                 "recipe_id" => r.lentil_stew.id,
                 "name" => "Alpha lentil stew"
               }
             ]
    end

    test "returns the Planned Meals of an inclusive range in date and slot order",
         %{household: h, recipes: r} do
      plan_week!(h, r)
      scheduled_meal!(h, ~D[2026-11-04], :breakfast, r.rice_salad)

      {_session_id, [result]} =
        run_tools(h, [{"get_plan", %{"from" => "2026-11-02", "to" => "2026-11-03"}}])

      assert Enum.map(result["meals"], &{&1["date"], &1["slot"]}) == [
               {"2026-11-02", "lunch"},
               {"2026-11-02", "dinner"},
               {"2026-11-03", "lunch"},
               {"2026-11-03", "dinner"}
             ]
    end

    test "never returns another Household's meals, whatever the arguments say",
         %{household: h, recipes: r} do
      other = household!("Other Fictitious Household")
      scheduled_meal!(other, @past_monday, :lunch, r.rice_salad)

      {_session_id, [result]} =
        run_tools(h, [
          {"get_plan",
           %{
             "from" => "2026-11-02",
             "household_id" => other.account_id,
             "account_id" => other.account_id
           }}
        ])

      assert result["meals"] == []
    end

    test "rejects missing, malformed, reversed and oversized ranges", %{household: h} do
      {_session_id, results} =
        run_tools(h, [
          {"get_plan", %{}},
          {"get_plan", %{"from" => "next monday"}},
          {"get_plan", %{"from" => "2026-11-03", "to" => "2026-11-02"}},
          {"get_plan", %{"from" => "2026-01-01", "to" => "2026-12-31"}}
        ])

      assert Enum.map(results, & &1["error"]) == List.duplicate("invalid_range", 4)
    end
  end
end
