defmodule MealPlannerApi.PlanningAgent.LivePricesTest do
  @moduledoc """
  Live prices and freshness through the session module with the scripted
  model and a fake scraper (issue #101, spec #93 user stories 44-47): the
  `lookup_prices` tool reads the database first and refreshes missing or
  stale prices live; failures keep the old price with its real age.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.PlanningAgent.{FakeOptimizer, FakeScraper}
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]
  @now ~U[2026-11-01 12:00:00.000000Z]
  @no_backoff %{read: %{backoff_ms: 0}}

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    %{household: household}
  end

  defp hours_ago(hours), do: DateTime.add(@now, -hours * 3600, :second)

  defp start!(household, script, opts) do
    attrs = session_attrs(household, household.owner, {@monday, @tuesday}, ["lunch"])

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, Keyword.get(opts, :optimizer, notify: self())},
        price_scraper:
          {FakeScraper, responses: Keyword.get(opts, :responses, %{}), notify: self()},
        clock: fn -> @now end,
        call_policies: @no_backoff,
        subscriber: self()
      )

    {session_id, pid}
  end

  # Runs one tool call and returns the tool result the model received.
  defp run_tool(household, name, arguments, opts \\ []) do
    {session_id, pid} =
      start!(household, [{:tool_calls, [{name, arguments}]}, {:text, "done"}], opts)

    :ok = Session.send_message(pid, "Go")
    assert_receive {:scripted_model_request, _first}
    assert_receive {:scripted_model_request, %{messages: messages}}
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
    :ok = Session.cancel(pid, %{membership_id: household.owner.membership_id, owner?: true})
    %{role: :tool_result, content: content} = List.last(messages)
    content
  end

  defp lookup(household, ingredient, opts \\ []),
    do: run_tool(household, "lookup_prices", %{"ingredients" => [ingredient.name]}, opts)

  describe "fresh prices" do
    test "come from the database without a live call", %{household: h} do
      pasta = ingredient!("Fictitious pasta")
      product!(pasta, price_cents: 1_250, observed_at: hours_ago(2))

      result = lookup(h, pasta)

      refute_received {:fake_scraper_fetch, _}
      assert [%{"price_cents" => 1_250, "fresh" => true, "age_hours" => 2}] = result["prices"]
      assert result["warnings"] == []
      assert result["outcome"] == "complete"
    end
  end

  describe "stale prices" do
    test "trigger a live lookup whose observation replaces the stale one", %{household: h} do
      oil = ingredient!("Fictitious oil")

      product!(oil,
        name: "Fictitious oil bottle",
        supermarket: "Fictitious Live Market",
        package: {1_000_000, :ml},
        price_cents: 900,
        observed_at: hours_ago(30)
      )

      live =
        FakeScraper.item(
          product: "Fictitious oil bottle",
          package_quantity_milli: 1_000_000,
          package_unit: :ml,
          price_cents: 1_100,
          observed_at: hours_ago(1)
        )

      result = lookup(h, oil, responses: %{String.downcase(oil.name) => {:ok, [live]}})

      assert_received {:fake_scraper_fetch, query}
      assert query == oil.name

      assert [%{"price_cents" => 1_100, "fresh" => true, "age_hours" => 1}] = result["prices"]
      assert result["warnings"] == []
      assert result["outcome"] == "complete"

      # The refreshed observation is stored: the next lookup needs no call.
      assert [%{"price_cents" => 1_100}] = lookup(h, oil)["prices"]
      refute_received {:fake_scraper_fetch, _}
    end

    test "a failed refresh keeps the old price with its real age and a warning",
         %{household: h} do
      rice = ingredient!("Fictitious rice")
      product!(rice, price_cents: 700, observed_at: hours_ago(30))
      responses = %{String.downcase(rice.name) => {:error, :scraper_unreachable}}

      result = lookup(h, rice, responses: responses)

      assert [%{"price_cents" => 700, "fresh" => false, "age_hours" => 30} = price] =
               result["prices"]

      assert price["observed_at"] == DateTime.to_iso8601(hours_ago(30))

      assert result["warnings"] == [
               %{
                 "ingredient" => rice.name,
                 "reason" => "refresh_failed",
                 "detail" => "scraper_unreachable"
               }
             ]

      assert result["outcome"] == "partial"

      # A failed refresh never renews the price's age.
      assert [%{"age_hours" => 30, "fresh" => false}] =
               lookup(h, rice, responses: responses)["prices"]
    end

    test "scraped data the database rejects is a failed refresh, never a crash",
         %{household: h} do
      rice = ingredient!("Fictitious rice")
      product!(rice, price_cents: 700, observed_at: hours_ago(30))
      too_long = FakeScraper.item(product: String.duplicate("x", 300), observed_at: hours_ago(1))

      result = lookup(h, rice, responses: %{String.downcase(rice.name) => {:ok, [too_long]}})

      assert [%{"price_cents" => 700, "fresh" => false, "age_hours" => 30}] = result["prices"]

      assert [%{"ingredient" => ingredient, "reason" => "refresh_failed"}] = result["warnings"]
      assert ingredient == rice.name
      assert result["outcome"] == "partial"
    end

    test "a transient scraper failure is retried within the read budget", %{household: h} do
      rice = ingredient!("Fictitious rice")
      product!(rice, observed_at: hours_ago(30))

      lookup(h, rice, responses: %{String.downcase(rice.name) => {:error, :scraper_unreachable}})

      # One attempt plus the two read retries.
      for _ <- 1..3, do: assert_received({:fake_scraper_fetch, _})
      refute_received {:fake_scraper_fetch, _}
    end

    test "a cached scraper observation keeps its own time and is still stale",
         %{household: h} do
      flour = ingredient!("Fictitious flour")

      product!(flour,
        name: "Fictitious flour bag",
        supermarket: "Fictitious Live Market",
        price_cents: 500,
        observed_at: hours_ago(40)
      )

      cached =
        FakeScraper.item(
          product: "Fictitious flour bag",
          price_cents: 520,
          observed_at: hours_ago(26),
          cached?: true
        )

      result = lookup(h, flour, responses: %{String.downcase(flour.name) => {:ok, [cached]}})

      assert [%{"price_cents" => 520, "fresh" => false, "age_hours" => 26}] = result["prices"]
      assert [%{"reason" => "still_stale", "ingredient" => name}] = result["warnings"]
      assert name == flour.name
      assert result["outcome"] == "partial"
    end
  end

  describe "missing prices" do
    test "trigger a live lookup that stores the new Product with provenance",
         %{household: h} do
      salt = ingredient!("Fictitious salt")

      live =
        FakeScraper.item(
          supermarket: "Fictitious Market South",
          product: "Fictitious fine salt",
          brand: "Fictitious Salt Co",
          package_quantity_milli: 500_000,
          price_cents: 300,
          observed_at: hours_ago(3)
        )

      result = lookup(h, salt, responses: %{String.downcase(salt.name) => {:ok, [live]}})

      assert [
               %{
                 "product" => "Fictitious fine salt",
                 "brand" => "Fictitious Salt Co",
                 "supermarket" => "Fictitious Market South",
                 "presentation" => %{"quantity_milli" => 500_000, "unit" => "g"},
                 "price_cents" => 300,
                 "currency" => "ARS",
                 "fresh" => true,
                 "age_hours" => 3
               }
             ] = result["prices"]

      assert result["missing"] == []
    end

    test "stay missing with a warning when the live lookup fails", %{household: h} do
      salt = ingredient!("Fictitious salt")
      responses = %{String.downcase(salt.name) => {:error, :scraper_unavailable}}

      result = lookup(h, salt, responses: responses)

      assert result["prices"] == []
      assert result["missing"] == [%{"ingredient" => salt.name, "reason" => "no_stored_price"}]

      assert result["warnings"] == [
               %{
                 "ingredient" => salt.name,
                 "reason" => "refresh_failed",
                 "detail" => "scraper_unavailable"
               }
             ]

      # A non-transient failure is not retried.
      assert_received {:fake_scraper_fetch, _}
      refute_received {:fake_scraper_fetch, _}
    end

    test "an unknown ingredient is never looked up live", %{household: h} do
      result = run_tool(h, "lookup_prices", %{"ingredients" => ["Unknown thing"]})

      refute_received {:fake_scraper_fetch, _}

      assert result["missing"] == [
               %{"ingredient" => "Unknown thing", "reason" => "unknown_ingredient"}
             ]
    end
  end

  describe "brand and product queries" do
    setup do
      pasta = ingredient!("Fictitious pasta")

      product!(pasta,
        name: "Fictitious spaghetti",
        brand: "Fictitious Luchetti",
        package: {500_000, :g},
        price_cents: 1_400,
        observed_at: hours_ago(1)
      )

      product!(pasta,
        name: "Fictitious penne",
        brand: "Fictitious Matarazzo",
        package: {500_000, :g},
        price_cents: 1_200,
        observed_at: hours_ago(1)
      )

      %{pasta: pasta}
    end

    test "a brand query returns only that brand's Products with prices",
         %{household: h, pasta: pasta} do
      result =
        run_tool(h, "lookup_prices", %{
          "ingredients" => [pasta.name],
          "brand" => "fictitious luchetti"
        })

      refute_received {:fake_scraper_fetch, _}

      assert [
               %{
                 "product" => "Fictitious spaghetti",
                 "brand" => "Fictitious Luchetti",
                 "price_cents" => 1_400
               }
             ] = result["prices"]

      assert result["missing"] == []
    end

    test "a brand missing from the database is looked up live",
         %{household: h, pasta: pasta} do
      live =
        FakeScraper.item(
          product: "Fictitious fusilli",
          brand: "Fictitious Don Vicente",
          package_quantity_milli: 500_000,
          price_cents: 1_600,
          observed_at: hours_ago(2)
        )

      result =
        run_tool(
          h,
          "lookup_prices",
          %{"ingredients" => [pasta.name], "brand" => "Fictitious Don Vicente"},
          responses: %{String.downcase(pasta.name) => {:ok, [live]}}
        )

      assert_received {:fake_scraper_fetch, _}
      assert [%{"brand" => "Fictitious Don Vicente", "price_cents" => 1_600}] = result["prices"]
    end

    test "a brand nobody sells is reported missing, never priced",
         %{household: h, pasta: pasta} do
      result =
        run_tool(h, "lookup_prices", %{"ingredients" => [pasta.name], "brand" => "Nonexistent"})

      assert result["prices"] == []

      assert result["missing"] == [
               %{
                 "ingredient" => pasta.name,
                 "brand" => "Nonexistent",
                 "reason" => "no_matching_brand"
               }
             ]

      assert result["outcome"] == "partial"
    end

    test "a Product query matches product names and brands across ingredients",
         %{household: h} do
      result = run_tool(h, "lookup_prices", %{"product" => "SPAGHETTI"})

      assert [%{"product" => "Fictitious spaghetti", "price_cents" => 1_400}] = result["prices"]

      assert [%{"product" => "Fictitious penne"}] =
               run_tool(h, "lookup_prices", %{"product" => "matarazzo"})["prices"]
    end

    test "a Product query combined with a brand narrows the match", %{household: h} do
      result =
        run_tool(h, "lookup_prices", %{
          "product" => "fictitious",
          "brand" => "Fictitious Matarazzo"
        })

      assert [%{"product" => "Fictitious penne"}] = result["prices"]
    end

    test "a Product query that matches nothing is reported missing", %{household: h} do
      result = run_tool(h, "lookup_prices", %{"product" => "Nonexistent product"})

      assert result["prices"] == []

      assert result["missing"] == [
               %{"product" => "Nonexistent product", "reason" => "no_matching_product"}
             ]

      # Wildcards are matched literally.
      assert run_tool(h, "lookup_prices", %{"product" => "%"})["prices"] == []
    end
  end

  describe "present_proposal" do
    test "shows stale purchase prices with their age and marks the budget uncertain",
         %{household: h} do
      rice = ingredient!("Fictitious rice")
      product!(rice, package: {1_000_000, :g}, price_cents: 800, observed_at: hours_ago(50))
      bowl = recipe!("Rice bowl", [rice], quantities: %{rice.id => {200_000, :g}})

      script = [
        {:tool_calls, [{"run_optimizer", %{}}]},
        {:tool_calls, [{"present_proposal", %{}}]},
        {:text, "done"}
      ]

      {session_id, pid} =
        start!(h, script, optimizer: [result: FakeOptimizer.everywhere(bowl.id)])

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal", "purchase" => purchase, "budget" => budget}}

      assert [%{"price_cents" => 800, "fresh" => false, "age_hours" => 50}] = purchase["lines"]

      assert [%{"ingredient" => name, "age_hours" => 50}] = purchase["stale_prices"]
      assert name == rice.name
      assert budget["uncertain"] == true
    end
  end
end
