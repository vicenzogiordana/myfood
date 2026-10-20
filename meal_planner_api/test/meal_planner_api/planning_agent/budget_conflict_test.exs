defmodule MealPlannerApi.PlanningAgent.BudgetConflictTest do
  @moduledoc """
  An infeasible budget through the session module with the scripted model
  (issue #148, battery A5): the agent never escapes a budget it cannot meet
  by creating recipes on its own. `present_proposal` names the real cause,
  and `create_recipe` refuses AI-created Recipe Drafts until the household
  answers.
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
    budget!(household, 1_000)

    rice = ingredient!("Fictitious rice")
    saffron = ingredient!("Fictitious saffron")

    recipe!("Fictitious saffron rice", [rice, saffron], quantities: %{saffron.id => {1_000, :g}})

    product!(rice, name: "Fictitious rice 1 kg", package: {1_000_000, :g}, price_cents: 200)
    # One tin alone exceeds the whole budget.
    product!(saffron, name: "Fictitious saffron tin", package: {100_000, :g}, price_cents: 9_000)

    %{household: household, rice: rice}
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

  defp run_turn!(session_id, pid, text) do
    :ok = Session.send_message(pid, text)
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}, 2_000
    last = drain_requests([]) |> List.last()
    for %{role: :tool_result, name: name, content: content} <- last.messages, do: {name, content}
  end

  defp drain_requests(acc) do
    receive do
      {:scripted_model_request, request} -> drain_requests(acc ++ [request])
    after
      0 -> acc
    end
  end

  defp last_result(results, name),
    do: for({^name, content} <- results, do: content) |> List.last()

  defp draft_args(ctx, origin) do
    %{
      "name" => "Fictitious plain rice",
      "servings" => 2,
      "slots" => ["lunch", "dinner"],
      "origin" => origin,
      "ingredients" => [%{"ingredient" => ctx.rice.name, "quantity" => 200, "unit" => "g"}],
      "steps" => ["Boil the rice."]
    }
  end

  defp plan_and_present,
    do: [
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]}
    ]

  test "a budget Deviation names the packages that alone exceed the budget", %{household: h} do
    {session_id, pid} = start!(h, plan_and_present() ++ [{:text, "It cannot fit."}])
    results = run_turn!(session_id, pid, "Plan Monday within our budget")

    assert %{"status" => "requires_approval", "budget_conflict" => conflict} =
             last_result(results, "present_proposal")

    assert conflict["budget_cents"] == 1_000
    assert conflict["over_by_cents"] > 0

    assert [%{"product" => "Fictitious saffron tin", "package_price_cents" => 9_000}] =
             conflict["packages_over_budget"]

    assert conflict["guidance"] =~ "ask"
    assert conflict["guidance"] =~ "new recipes"
  end

  test "no AI-created Recipe Draft escapes a budget Deviation before the household answers",
       %{household: h} = ctx do
    script =
      plan_and_present() ++
        [
          {:tool_calls, [{"create_recipe", draft_args(ctx, "ai_created")}]},
          {:tool_calls, [{"ask_human", %{"question" => "Shall I create new recipes?"}}]},
          # The household asks for new recipes: the next turn may draft them.
          {:tool_calls, [{"create_recipe", draft_args(ctx, "ai_created")}]},
          {:text, "I drafted a recipe without saffron."}
        ]

    {session_id, pid} = start!(h, script)
    results = run_turn!(session_id, pid, "Plan Monday within our budget")

    assert %{"error" => "new_recipes_not_requested", "reason" => reason} =
             last_result(results, "create_recipe")

    assert reason =~ "ask"
    refute_received {:planning_agent_event, ^session_id, %{"type" => "recipe_draft"}}

    results = run_turn!(session_id, pid, "Yes, please create new recipes without saffron")

    assert %{"status" => "drafted"} = last_result(results, "create_recipe")
    assert_received {:planning_agent_event, ^session_id, %{"type" => "recipe_draft"}}
  end

  test "a recipe the Member dictates is still built during a budget Deviation",
       %{household: h} = ctx do
    script =
      plan_and_present() ++
        [{:tool_calls, [{"create_recipe", draft_args(ctx, "user_created")}]}, {:text, "ok"}]

    {session_id, pid} = start!(h, script)
    results = run_turn!(session_id, pid, "Here is my plain rice recipe")

    assert %{"status" => "drafted"} = last_result(results, "create_recipe")
  end

  test "without a budget Deviation an AI-created Draft is allowed", %{household: h} = ctx do
    budget!(h, 100_000)

    script =
      plan_and_present() ++
        [{:tool_calls, [{"create_recipe", draft_args(ctx, "ai_created")}]}, {:text, "ok"}]

    {session_id, pid} = start!(h, script)
    results = run_turn!(session_id, pid, "Plan Monday")

    assert %{"status" => "valid"} = last_result(results, "present_proposal")
    refute Map.has_key?(last_result(results, "present_proposal"), "budget_conflict")
    assert %{"status" => "drafted"} = last_result(results, "create_recipe")
  end
end
