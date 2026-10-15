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

  describe "reuse_plan" do
    test "reusing the week before last produces a fresh Proposal that passes full validation",
         %{household: h, recipes: r} do
      plan_week!(h, r)

      {session_id, [reused, presented]} =
        run_tools(h, [
          {"reuse_plan", %{"source_from" => "2026-11-02"}},
          {"present_proposal", %{}}
        ])

      expected = [
        {"2026-11-16", "lunch", r.rice_salad.id},
        {"2026-11-16", "dinner", r.lentil_stew.id},
        {"2026-11-17", "lunch", r.lentil_stew.id},
        {"2026-11-17", "dinner", r.chicken_rice.id}
      ]

      assert reused["status"] == "ok"
      assert Enum.map(reused["meals"], &{&1["date"], &1["slot"], &1["recipe_id"]}) == expected
      assert presented["status"] == "valid"

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal", "status" => "valid", "meals" => meals} = proposal}

      assert proposal["proposal_id"] == presented["proposal_id"]
      assert Enum.map(meals, &{&1["date"], &1["slot"], &1["recipe_id"]}) == expected
      refute_received {:optimizer_payload, _}
    end

    test "only the session's slots are reused and dates follow the Planning Range",
         %{household: h, recipes: r} do
      plan_week!(h, r)
      scheduled_meal!(h, @past_monday, :breakfast, r.rice_salad)

      {_session_id, [reused]} =
        run_tools(h, [{"reuse_plan", %{"source_from" => "2026-11-02"}}])

      assert Enum.map(reused["meals"], &{&1["date"], &1["slot"]}) == [
               {"2026-11-16", "lunch"},
               {"2026-11-16", "dinner"},
               {"2026-11-17", "lunch"},
               {"2026-11-17", "dinner"}
             ]
    end

    test "a reused meal that breaks a current Restriction is not shown, so no past " <>
           "Absence Exception carries over",
         %{household: h, recipes: r} do
      # The past Tuesday dinner held meat, e.g. while the vegetarian Member was
      # away under an Absence Exception. Reuse must revalidate it today.
      plan_week!(h, r)
      diet!(member!(h), :vegetarian)

      {session_id, [_reused, presented]} =
        run_tools(h, [
          {"reuse_plan", %{"source_from" => "2026-11-02"}},
          {"present_proposal", %{}}
        ])

      assert presented["status"] == "invalid"

      assert [%{"type" => "restriction_conflict", "date" => "2026-11-17", "slot" => "dinner"}] =
               presented["violations"]

      refute_received {:planning_agent_event, ^session_id, %{"type" => "proposal"}}
    end

    test "gaps of the past week are reported by the validator, never filled silently",
         %{household: h, recipes: r} do
      scheduled_meal!(h, @past_monday, :lunch, r.rice_salad)
      scheduled_meal!(h, @past_monday, :dinner, r.lentil_stew)

      {_session_id, [reused, presented]} =
        run_tools(h, [
          {"reuse_plan", %{"source_from" => "2026-11-02"}},
          {"present_proposal", %{}}
        ])

      assert length(reused["meals"]) == 2
      assert presented["status"] == "invalid"

      assert Enum.map(presented["violations"], &{&1["type"], &1["date"], &1["slot"]}) == [
               {"missing_meal", "2026-11-17", "lunch"},
               {"missing_meal", "2026-11-17", "dinner"}
             ]
    end

    test "carries over only day, slot and recipe: no portions, approvals or exceptions",
         %{household: h, recipes: r} do
      plan_week!(h, r)

      {session_id, [reused, _presented]} =
        run_tools(h, [
          {"reuse_plan", %{"source_from" => "2026-11-02"}},
          {"present_proposal", %{}}
        ])

      assert Enum.all?(reused["meals"], &(Map.keys(&1) == ~w(date name recipe_id slot)))

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal", "meals" => meals} = proposal}

      assert Map.keys(proposal) ==
               ~w(budget consumed_cost deviations meals proposal_id purchase status type)

      assert Enum.all?(meals, &(Map.keys(&1) == ~w(date name recipe_id slot)))
    end

    test "never reuses another Household's meals", %{household: h, recipes: r} do
      other = household!("Other Fictitious Household")
      plan_week!(other, r)

      {_session_id, [reused, presented]} =
        run_tools(h, [
          {"reuse_plan", %{"source_from" => "2026-11-02", "account_id" => other.account_id}},
          {"present_proposal", %{}}
        ])

      assert reused == %{"error" => "no_planned_meals"}
      assert presented == %{"error" => "no_plan_to_present"}
    end

    test "rejects a source that is malformed or not entirely before the Planning Range",
         %{household: h} do
      {_session_id, results} =
        run_tools(h, [
          {"reuse_plan", %{}},
          {"reuse_plan", %{"source_from" => "last week"}},
          {"reuse_plan", %{"source_from" => "2026-11-16"}},
          {"reuse_plan", %{"source_from" => "2026-11-15"}}
        ])

      assert Enum.map(results, & &1["error"]) == List.duplicate("invalid_source", 4)
    end
  end
end
