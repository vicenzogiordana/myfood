defmodule MealPlannerApi.PlanningAgent.BrandsTest do
  @moduledoc """
  Brands through the session module with the scripted model, a fake
  optimizer and a fake scraper (issue #101, spec #93 user stories 50-54):
  Household Brand Preferences come from household settings, Session Brands
  live only in the Workspace, and the Purchase never swaps a chosen brand
  without telling the Member.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.BrandPreferences
  alias MealPlannerApi.PlanningAgent.{FakeOptimizer, FakeScraper}
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session

  @monday ~D[2026-11-02]
  @now ~U[2026-11-01 12:00:00.000000Z]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    %{household: household}
  end

  defp start!(household, script, opts \\ []) do
    attrs = session_attrs(household, household.owner, {@monday, @monday}, ["lunch"])

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, Keyword.get(opts, :optimizer, [])},
        price_scraper: {FakeScraper, responses: %{}, notify: self()},
        clock: fn -> @now end,
        deadline_ms: Keyword.get(opts, :deadline_ms, 300_000),
        subscriber: self()
      )

    {session_id, pid}
  end

  describe "Household Brand Preferences" do
    test "come from household settings into the agent's instructions", %{household: h} do
      pasta = ingredient!("Fictitious pasta")
      {:ok, _} = BrandPreferences.put(h.account_id, pasta.id, "Fictitious Luchetti")

      {_session_id, pid} = start!(h, [{:text, "Hello"}])
      :ok = Session.send_message(pid, "Hi")

      assert_receive {:scripted_model_request, %{instructions: instructions}}
      assert instructions =~ "#{pasta.name}: Fictitious Luchetti"
    end

    test "of another Household never reach this session", %{household: h} do
      pasta = ingredient!("Fictitious pasta")
      other = household!("Other Fictitious Household")
      {:ok, _} = BrandPreferences.put(other.account_id, pasta.id, "Fictitious Other Brand")

      {_session_id, pid} = start!(h, [{:text, "Hello"}])
      :ok = Session.send_message(pid, "Hi")

      assert_receive {:scripted_model_request, %{instructions: instructions}}
      refute instructions =~ "Fictitious Other Brand"
    end
  end

  # One lunch of a recipe needing 400 g of pasta. Two fresh pasta brands:
  # the cheaper one is not the household's choice.
  defp pasta_world!(household) do
    pasta = ingredient!("Fictitious pasta")
    recipe = recipe!("Pasta dish", [pasta], quantities: %{pasta.id => {400_000, :g}})

    product!(pasta,
      name: "Fictitious spaghetti",
      brand: "Fictitious Luchetti",
      package: {500_000, :g},
      price_cents: 1_400,
      observed_at: ~U[2026-11-01 10:00:00.000000Z]
    )

    product!(pasta,
      name: "Fictitious penne",
      brand: "Fictitious Matarazzo",
      package: {500_000, :g},
      price_cents: 1_000,
      observed_at: ~U[2026-11-01 10:00:00.000000Z]
    )

    _ = household
    %{pasta: pasta, recipe: recipe}
  end

  # Runs `calls` (one model step each), then the optimizer and
  # present_proposal; returns the proposal event, the present_proposal
  # result and every session_brand_changed event.
  defp present!(household, recipe, calls \\ []) do
    script =
      Enum.map(calls, &{:tool_calls, [&1]}) ++
        [
          {:tool_calls, [{"run_optimizer", %{}}]},
          {:tool_calls, [{"present_proposal", %{}}]},
          {:text, "done"}
        ]

    {session_id, pid} =
      start!(household, script, optimizer: [result: FakeOptimizer.everywhere(recipe.id)])

    :ok = Session.send_message(pid, "Plan")

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

    requests = drain_requests([])
    %{content: result} = requests |> List.last() |> Map.fetch!(:messages) |> List.last()

    %{
      session_id: session_id,
      pid: pid,
      proposal: proposal,
      result: result,
      tool_results: tool_results(requests),
      brand_events: drain_brand_events(session_id, [])
    }
  end

  defp drain_requests(acc) do
    receive do
      {:scripted_model_request, request} -> drain_requests(acc ++ [request])
    after
      0 -> acc
    end
  end

  defp tool_results(requests) do
    requests
    |> List.last()
    |> Map.fetch!(:messages)
    |> Enum.filter(&(&1.role == :tool_result))
    |> Enum.map(& &1.content)
  end

  defp drain_brand_events(session_id, acc) do
    receive do
      {:planning_agent_event, ^session_id, %{"type" => "session_brand_changed"} = event} ->
        drain_brand_events(session_id, acc ++ [event])
    after
      0 -> acc
    end
  end

  describe "Purchase with brands" do
    test "buys the cheapest Product when no brand is chosen", %{household: h} do
      %{recipe: recipe} = pasta_world!(h)

      %{proposal: proposal} = present!(h, recipe)

      assert [%{"brand" => "Fictitious Matarazzo", "brand_choice" => nil}] =
               proposal["purchase"]["lines"]
    end

    test "honours a Brand Preference even when another brand is cheaper, and names the alternative",
         %{household: h} do
      %{pasta: pasta, recipe: recipe} = pasta_world!(h)
      {:ok, _} = BrandPreferences.put(h.account_id, pasta.id, "Fictitious Luchetti")

      %{proposal: proposal} = present!(h, recipe)

      assert [line] = proposal["purchase"]["lines"]
      assert line["brand"] == "Fictitious Luchetti"
      assert line["total_cents"] == 1_400

      assert line["brand_choice"] == %{
               "brand" => "Fictitious Luchetti",
               "source" => "household",
               "honoured" => true
             }

      assert line["cheaper_alternative"] == %{
               "product" => "Fictitious penne",
               "brand" => "Fictitious Matarazzo",
               "packages" => 1,
               "total_cents" => 1_000,
               "difference_cents" => 400
             }

      assert proposal["purchase"]["brand_substitutions"] == []
    end

    test "a Session Brand overrides the Brand Preference and the change is shown to the Member",
         %{household: h} do
      %{pasta: pasta, recipe: recipe} = pasta_world!(h)
      {:ok, _} = BrandPreferences.put(h.account_id, pasta.id, "Fictitious Luchetti")

      %{proposal: proposal, brand_events: events, tool_results: [set | _]} =
        present!(h, recipe, [
          {"set_session_brand", %{"ingredient" => pasta.name, "brand" => "fictitious matarazzo"}}
        ])

      assert set["status"] == "ok"

      assert events == [
               %{
                 "type" => "session_brand_changed",
                 "ingredient" => pasta.name,
                 "brand" => "Fictitious Matarazzo",
                 "source" => "session",
                 "previous_brand" => "Fictitious Luchetti",
                 "previous_source" => "household"
               }
             ]

      assert [%{"brand" => "Fictitious Matarazzo", "brand_choice" => choice}] =
               proposal["purchase"]["lines"]

      assert choice == %{
               "brand" => "Fictitious Matarazzo",
               "source" => "session",
               "honoured" => true
             }

      # Household settings are untouched.
      assert [%{brand: "Fictitious Luchetti"}] = BrandPreferences.list(h.account_id)
    end

    test "a Session Brand lives only in its Planning Session's Workspace", %{household: h} do
      %{pasta: pasta, recipe: recipe} = pasta_world!(h)

      %{pid: pid} =
        present!(h, recipe, [
          {"set_session_brand", %{"ingredient" => pasta.name, "brand" => "Fictitious Luchetti"}}
        ])

      :ok = Session.cancel(pid, %{membership_id: h.owner.membership_id, owner?: true})

      %{proposal: proposal} = present!(h, recipe)

      assert [%{"brand" => "Fictitious Matarazzo", "brand_choice" => nil}] =
               proposal["purchase"]["lines"]

      assert BrandPreferences.list(h.account_id) == []
    end

    test "clearing a Session Brand falls back to the Brand Preference, visibly", %{household: h} do
      %{pasta: pasta, recipe: recipe} = pasta_world!(h)
      {:ok, _} = BrandPreferences.put(h.account_id, pasta.id, "Fictitious Luchetti")

      %{proposal: proposal, brand_events: events} =
        present!(h, recipe, [
          {"set_session_brand", %{"ingredient" => pasta.name, "brand" => "Fictitious Matarazzo"}},
          {"set_session_brand", %{"ingredient" => pasta.name, "brand" => nil}}
        ])

      assert [_set, cleared] = events

      assert cleared == %{
               "type" => "session_brand_changed",
               "ingredient" => pasta.name,
               "brand" => "Fictitious Luchetti",
               "source" => "household",
               "previous_brand" => "Fictitious Matarazzo",
               "previous_source" => "session"
             }

      assert [%{"brand" => "Fictitious Luchetti"}] = proposal["purchase"]["lines"]
    end

    test "a chosen brand that cannot be bought is never swapped silently", %{household: h} do
      %{pasta: pasta, recipe: recipe} = pasta_world!(h)

      # Only sold in a presentation in another unit than the recipe needs.
      product!(pasta,
        name: "Fictitious pasta tray",
        brand: "Fictitious Tray Brand",
        package: {6_000, :unit},
        price_cents: 500,
        observed_at: ~U[2026-11-01 10:00:00.000000Z]
      )

      {:ok, _} = BrandPreferences.put(h.account_id, pasta.id, "Fictitious Tray Brand")

      %{proposal: proposal, result: result} = present!(h, recipe)

      assert [line] = proposal["purchase"]["lines"]
      assert line["brand"] == "Fictitious Matarazzo"

      assert line["brand_choice"] == %{
               "brand" => "Fictitious Tray Brand",
               "source" => "household",
               "honoured" => false
             }

      substitution = %{
        "ingredient" => pasta.name,
        "chosen_brand" => "Fictitious Tray Brand",
        "source" => "household",
        "bought_brand" => "Fictitious Matarazzo",
        "bought_product" => "Fictitious penne",
        "reason" => "brand_unavailable"
      }

      assert proposal["purchase"]["brand_substitutions"] == [substitution]
      assert result["brand_substitutions"] == [substitution]
    end

    test "a budget conflict caused by a chosen brand is answered with the alternative and its difference",
         %{household: h} do
      %{pasta: pasta, recipe: recipe} = pasta_world!(h)
      {:ok, _} = BrandPreferences.put(h.account_id, pasta.id, "Fictitious Luchetti")
      budget!(h, 1_200)

      %{proposal: proposal, result: result} = present!(h, recipe)

      # The chosen brand is still what the Purchase buys.
      assert [%{"brand" => "Fictitious Luchetti"}] = proposal["purchase"]["lines"]
      assert result["status"] == "requires_approval"

      assert result["brand_alternatives"] == [
               %{
                 "ingredient" => pasta.name,
                 "chosen_brand" => "Fictitious Luchetti",
                 "source" => "household",
                 "chosen_total_cents" => 1_400,
                 "alternative_product" => "Fictitious penne",
                 "alternative_brand" => "Fictitious Matarazzo",
                 "alternative_total_cents" => 1_000,
                 "difference_cents" => 400
               }
             ]
    end

    test "within the budget no brand alternative is pushed", %{household: h} do
      %{pasta: pasta, recipe: recipe} = pasta_world!(h)
      {:ok, _} = BrandPreferences.put(h.account_id, pasta.id, "Fictitious Luchetti")
      budget!(h, 5_000)

      %{result: result} = present!(h, recipe)

      assert result["status"] == "valid"
      assert result["brand_alternatives"] == []
    end
  end

  describe "set_session_brand" do
    test "rejects an unknown ingredient, a brand no Product of it has and a blank brand",
         %{household: h} do
      %{pasta: pasta} = pasta_world!(h)

      calls = [
        {"set_session_brand", %{"ingredient" => "Unknown thing", "brand" => "Any"}},
        {"set_session_brand", %{"ingredient" => pasta.name, "brand" => "Nonexistent"}},
        {"set_session_brand", %{"ingredient" => pasta.name, "brand" => "  "}}
      ]

      {session_id, pid} = start!(h, [{:tool_calls, calls}, {:text, "done"}])
      :ok = Session.send_message(pid, "Brands")

      assert_receive {:scripted_model_request, _first}
      assert_receive {:scripted_model_request, %{messages: messages}}
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

      errors =
        messages |> Enum.filter(&(&1.role == :tool_result)) |> Enum.map(& &1.content["error"])

      assert errors == ["unknown_ingredient", "unknown_brand", "brand_required"]
      assert drain_brand_events(session_id, []) == []
    end

    # Issue #160: an Ingredient spelled otherwise is offered by its catalog name.
    test "an unknown ingredient lists close catalog matches", %{household: h} do
      %{pasta: pasta} = pasta_world!(h)
      typo = String.replace(pasta.name, "pasta", "pastta")

      calls = [{"set_session_brand", %{"ingredient" => typo, "brand" => "Any"}}]
      {session_id, pid} = start!(h, [{:tool_calls, calls}, {:text, "done"}])
      :ok = Session.send_message(pid, "Brands")

      assert_receive {:scripted_model_request, _first}
      assert_receive {:scripted_model_request, %{messages: messages}}
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

      %{content: result} = List.last(messages)
      assert result["error"] == "unknown_ingredient"
      assert hd(result["close_matches"]) == pasta.name
    end

    test "a Session Brand shown to the Member survives a turn cut by the deadline",
         %{household: h} do
      %{pasta: pasta} = pasta_world!(h)
      slow = fn _request -> Process.sleep(1_000) && {:text, "late"} end

      script = [
        {:tool_calls,
         [{"set_session_brand", %{"ingredient" => pasta.name, "brand" => "Fictitious Luchetti"}}]},
        slow
      ]

      {session_id, pid} = start!(h, script, deadline_ms: 300)
      :ok = Session.send_message(pid, "Brands")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "session_brand_changed", "brand" => "Fictitious Luchetti"}},
                     1_000

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "time"}},
                     1_000

      assert %{workspace: %{session_brands: brands}} = :sys.get_state(pid)
      assert %{brand: "Fictitious Luchetti"} = brands[pasta.id]
    end
  end
end
