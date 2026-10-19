defmodule MealPlannerApi.PlanningAgent.PurchaseToolsTest do
  @moduledoc """
  Prices, Projected Pantry and Purchase through the session module with the
  scripted model and a fake optimizer (issue #100, spec #93): the
  `lookup_prices` and `get_pantry` tools and the Purchase carried by
  `present_proposal`.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]
  @now ~U[2026-10-14 12:00:00.000000Z]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    %{household: household}
  end

  defp start!(household, script, opts \\ []) do
    {range, opts} = Keyword.pop(opts, :range, {@monday, @tuesday})
    {slots, opts} = Keyword.pop(opts, :slots, ["lunch", "dinner"])
    attrs = session_attrs(household, household.owner, range, slots)

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, Keyword.merge([notify: self()], opts)},
        # Fixture prices are observed on 2026-10-14 10:00 UTC: fresh here.
        clock: fn -> @now end,
        subscriber: self()
      )

    {session_id, pid}
  end

  # Runs one tool call and returns the tool result the model received.
  defp run_tool(household, name, arguments) do
    {session_id, pid} =
      start!(household, [{:tool_calls, [{name, arguments}]}, {:text, "done"}])

    :ok = Session.send_message(pid, "Go")
    assert_receive {:scripted_model_request, _first}
    assert_receive {:scripted_model_request, %{messages: messages}}
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
    %{role: :tool_result, content: content} = List.last(messages)
    content
  end

  describe "lookup_prices" do
    test "returns stored prices with full provenance", %{household: h} do
      pasta = ingredient!("Fictitious pasta")

      _ =
        product!(pasta,
          name: "Fictitious spaghetti",
          brand: "Fictitious Brand",
          package: {500_000, :g},
          price_cents: 1_250,
          supermarket: "Fictitious Market North",
          observed_at: ~U[2026-10-13 09:30:00.000000Z]
        )

      result = run_tool(h, "lookup_prices", %{"ingredients" => [pasta.name]})

      assert [
               %{
                 "ingredient" => name,
                 "product" => "Fictitious spaghetti",
                 "brand" => "Fictitious Brand",
                 "presentation" => %{"quantity_milli" => 500_000, "unit" => "g"},
                 "supermarket" => "Fictitious Market North",
                 "price_cents" => 1_250,
                 "currency" => "ARS",
                 "observed_at" => "2026-10-13T09:30:00.000000Z"
               }
             ] = result["prices"]

      assert name == pasta.name
      assert result["missing"] == []
    end

    test "only the latest observation of a Product counts", %{household: h} do
      oil = ingredient!("Fictitious oil")

      product =
        product!(oil,
          package: {1_000_000, :ml},
          price_cents: 900,
          observed_at: ~U[2026-10-01 08:00:00.000000Z]
        )

      price_observation!(product, 1_100, observed_at: ~U[2026-10-12 08:00:00.000000Z])

      assert [%{"price_cents" => 1_100, "observed_at" => "2026-10-12T08:00:00.000000Z"}] =
               run_tool(h, "lookup_prices", %{"ingredients" => [oil.name]})["prices"]
    end

    test "an ingredient without a stored price is flagged missing, never priced",
         %{household: h} do
      salt = ingredient!("Fictitious salt")

      result = run_tool(h, "lookup_prices", %{"ingredients" => [salt.name, "Unknown thing"]})

      assert result["prices"] == []

      assert Enum.sort_by(result["missing"], & &1["ingredient"]) == [
               %{"ingredient" => salt.name, "reason" => "no_stored_price"},
               %{"ingredient" => "Unknown thing", "reason" => "unknown_ingredient"}
             ]
    end

    test "requires a list of ingredient names", %{household: h} do
      assert %{"error" => "ingredients_required"} = run_tool(h, "lookup_prices", %{})
    end

    for {label, args} <- [
          {"a blank product", %{"product" => "  "}},
          {"no ingredients and a blank product", %{"ingredients" => [], "product" => "\n"}},
          {"only blank names", %{"ingredients" => ["  ", ""]}}
        ] do
      test "requires ingredients given #{label}", %{household: h} do
        assert %{"error" => "ingredients_required"} =
                 run_tool(h, "lookup_prices", unquote(Macro.escape(args)))
      end
    end

    test "declares the ingredient names as required" do
      %{parameters: parameters, description: description} =
        Enum.find(MealPlannerApi.PlanningAgent.Tools.definitions(), &(&1.name == "lookup_prices"))

      assert parameters["required"] == ["ingredients"]
      assert description =~ "ingredients are required"
    end
  end

  describe "get_pantry" do
    test "subtracts stock committed to pending Planned Meals, including outside the range",
         %{household: h} do
      rice = ingredient!("Fictitious rice")
      flour = ingredient!("Fictitious flour")
      pantry!(h, rice, 1_000_000)
      pantry!(h, flour, 300_000)

      rice_bowl = recipe!("Rice bowl", [rice], quantities: %{rice.id => {200_000, :g}})
      bread = recipe!("Flat bread", [flour], quantities: %{flour.id => {500_000, :g}})

      # After the new range: still committed.
      scheduled_meal!(h, ~D[2026-11-10], :lunch, rice_bowl, selected_quantity: 2)
      # Cooked: no longer committed.
      scheduled_meal!(h, ~D[2026-11-11], :lunch, rice_bowl, is_cooked: true)
      # Commitment above stock: nothing left, never negative.
      scheduled_meal!(h, ~D[2026-11-12], :dinner, bread)

      items = run_tool(h, "get_pantry", %{})["items"]

      assert %{
               "unit" => "g",
               "on_hand_milli" => 1_000_000,
               "committed_milli" => 400_000,
               "available_milli" => 600_000
             } = Enum.find(items, &(&1["ingredient"] == rice.name))

      assert %{"on_hand_milli" => 300_000, "committed_milli" => 500_000, "available_milli" => 0} =
               Enum.find(items, &(&1["ingredient"] == flour.name))
    end

    test "lists nothing for an empty Pantry", %{household: h} do
      assert run_tool(h, "get_pantry", %{})["items"] == []
    end

    test "expired lots are not part of the Pantry", %{household: h} do
      milk = ingredient!("Fictitious milk")
      pantry!(h, milk, 500_000, :ml, expired_at: DateTime.add(DateTime.utc_now(), -3, :day))

      assert run_tool(h, "get_pantry", %{})["items"] == []
    end
  end

  describe "present_proposal Purchase" do
    # One day, lunch and dinner: both meals use the same recipe, so every
    # ingredient is needed twice.
    setup %{household: h} do
      pasta = ingredient!("Fictitious pasta")
      rice = ingredient!("Fictitious rice")

      recipe =
        recipe!("Pasta and rice", [pasta, rice],
          quantities: %{pasta.id => {100_000, :g}, rice.id => {200_000, :g}}
        )

      product!(pasta,
        name: "Fictitious penne",
        brand: "Fictitious Brand",
        package: {500_000, :g},
        price_cents: 1_000,
        supermarket: "Fictitious Market North",
        observed_at: ~U[2026-10-14 09:30:00.000000Z]
      )

      product!(rice, name: "Fictitious rice 500 g", package: {500_000, :g}, price_cents: 800)
      product!(rice, name: "Fictitious rice 1 kg", package: {1_000_000, :g}, price_cents: 1_200)

      # 350 g on hand, 200 g committed to a pending meal after the range:
      # 150 g of rice is available to the new Proposal.
      pantry!(h, rice, 350_000)
      other = recipe!("Plain rice", [rice], quantities: %{rice.id => {200_000, :g}})
      scheduled_meal!(h, ~D[2026-11-10], :lunch, other)

      %{pasta: pasta, rice: rice, recipe: recipe}
    end

    defp present!(household, recipe) do
      {session_id, pid} =
        start!(
          household,
          [
            {:tool_calls, [{"run_optimizer", %{}}]},
            {:tool_calls, [{"present_proposal", %{}}]},
            {:text, "Here is your plan."}
          ],
          range: {@monday, @monday},
          result: FakeOptimizer.everywhere(recipe.id)
        )

      :ok = Session.send_message(pid, "Plan Monday")

      assert_receive {:scripted_model_request, _}
      assert_receive {:scripted_model_request, _}
      assert_receive {:scripted_model_request, %{messages: messages}}
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

      %{role: :tool_result, content: tool_result} = List.last(messages)
      {proposal, tool_result}
    end

    defp line_for(proposal, ingredient),
      do: Enum.find(proposal["purchase"]["lines"], &(&1["ingredient"] == ingredient.name))

    test "rounds up to whole packages, counts each purchase once and nets the Projected Pantry",
         %{household: h, pasta: pasta, rice: rice, recipe: recipe} do
      {proposal, _} = present!(h, recipe)

      # 2 x 100 g of pasta is one 500 g package, not one per meal.
      assert %{
               "quantity_milli" => 200_000,
               "unit" => "g",
               "packages" => 1,
               "product" => "Fictitious penne",
               "brand" => "Fictitious Brand",
               "presentation" => %{"quantity_milli" => 500_000, "unit" => "g"},
               "supermarket" => "Fictitious Market North",
               "price_cents" => 1_000,
               "currency" => "ARS",
               "observed_at" => "2026-10-14T09:30:00.000000Z",
               "total_cents" => 1_000
             } = line_for(proposal, pasta)

      # 400 g needed, 150 g available: 250 g to buy, cheapest as one 500 g bag.
      assert %{
               "quantity_milli" => 250_000,
               "packages" => 1,
               "product" => "Fictitious rice 500 g",
               "total_cents" => 800
             } = line_for(proposal, rice)

      assert length(proposal["purchase"]["lines"]) == 2

      assert %{"total_cents" => 1_800, "currency" => "ARS", "complete" => true} =
               proposal["purchase"]

      assert proposal["purchase"]["missing_prices"] == []
    end

    test "chooses the presentation with the lowest package total", %{household: h} do
      oats = ingredient!("Fictitious oats")
      recipe = recipe!("Oat porridge", [oats], quantities: %{oats.id => {300_000, :g}})
      product!(oats, name: "Oats 500 g", package: {500_000, :g}, price_cents: 1_000)
      product!(oats, name: "Oats 1 kg", package: {1_000_000, :g}, price_cents: 1_500)

      {proposal, _} = present!(h, recipe)

      # 600 g: two 500 g bags cost 2,000; one 1 kg bag costs 1,500.
      assert %{"product" => "Oats 1 kg", "packages" => 1, "total_cents" => 1_500} =
               line_for(proposal, oats)
    end

    test "consumed-ingredient cost is reported separately from the Purchase",
         %{household: h, recipe: recipe} do
      {proposal, tool_result} = present!(h, recipe)

      # Pasta: 200 g at 1,000 per 500 g = 400. Rice: 400 g at the lowest unit
      # price, 1,200 per 1 kg = 480. Pantry stock is consumed too.
      assert %{"total_cents" => 880, "currency" => "ARS", "complete" => true} =
               proposal["consumed_cost"]

      assert proposal["purchase"]["total_cents"] == 1_800
      assert tool_result["consumed_cost_cents"] == 880
      assert tool_result["purchase_total_cents"] == 1_800
    end

    test "the budget is compared against the Purchase total; overspend is a budget Deviation",
         %{household: h, recipe: recipe} do
      # Above the consumed cost (880) but below the Purchase (1,800).
      budget!(h, 1_500)

      {proposal, tool_result} = present!(h, recipe)

      assert proposal["status"] == "requires_approval"

      assert proposal["deviations"] == [
               %{
                 "type" => "budget",
                 "budget_cents" => 1_500,
                 "total_cents" => 1_800,
                 "difference_cents" => 300
               }
             ]

      assert proposal["budget"] == %{
               "budget_cents" => 1_500,
               "purchase_total_cents" => 1_800,
               "within_budget" => false,
               "uncertain" => false
             }

      assert tool_result["status"] == "requires_approval"
      assert tool_result["deviations"] == proposal["deviations"]
    end

    test "a Purchase within the budget is valid without Deviations",
         %{household: h, recipe: recipe} do
      budget!(h, 2_000)

      {proposal, tool_result} = present!(h, recipe)

      assert proposal["status"] == "valid"
      assert proposal["deviations"] == []
      assert proposal["budget"]["within_budget"] == true
      assert tool_result["status"] == "valid"
    end

    test "missing prices are flagged as uncertainty, never zero or invented",
         %{household: h, pasta: pasta} do
      saffron = ingredient!("Fictitious saffron")
      eggs = ingredient!("Fictitious eggs")
      # Eggs are only sold by the unit; the recipe asks for grams.
      product!(eggs, name: "Eggs x6", package: {6_000, :unit}, price_cents: 900)

      recipe =
        recipe!("Saffron pasta", [pasta, saffron, eggs],
          quantities: %{
            pasta.id => {100_000, :g},
            saffron.id => {1_000, :g},
            eggs.id => {50_000, :g}
          }
        )

      budget!(h, 5_000)

      {proposal, tool_result} = present!(h, recipe)

      purchase = proposal["purchase"]
      assert [%{"ingredient" => ingredient}] = purchase["lines"]
      assert ingredient == pasta.name
      assert purchase["total_cents"] == 1_000
      assert purchase["complete"] == false

      assert Enum.sort_by(purchase["missing_prices"], & &1["reason"]) == [
               %{
                 "ingredient" => eggs.name,
                 "quantity_milli" => 100_000,
                 "unit" => "g",
                 "reason" => "no_matching_presentation"
               },
               %{
                 "ingredient" => saffron.name,
                 "quantity_milli" => 2_000,
                 "unit" => "g",
                 "reason" => "no_stored_price"
               }
             ]

      refute Enum.any?(purchase["lines"], &(&1["price_cents"] in [0, nil]))
      assert proposal["consumed_cost"]["complete"] == false
      # The total is only a lower bound: whether it fits is unknown.
      assert proposal["budget"]["uncertain"] == true
      assert proposal["budget"]["within_budget"] == nil
      assert proposal["deviations"] == []
      assert tool_result["purchase_complete"] == false
      assert length(tool_result["missing_prices"]) == 2
    end

    test "a household without a budget gets no budget Deviation",
         %{household: h, recipe: recipe} do
      {proposal, _} = present!(h, recipe)

      assert proposal["status"] == "valid"
      assert proposal["deviations"] == []

      assert proposal["budget"] == %{
               "budget_cents" => nil,
               "purchase_total_cents" => 1_800,
               "within_budget" => nil,
               "uncertain" => false
             }
    end
  end
end
