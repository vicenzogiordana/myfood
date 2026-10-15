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

    test "expired lots are not part of the Pantry", %{household: h} do
      milk = ingredient!("Fictitious milk")
      pantry!(h, milk, 500_000, :ml, expired_at: DateTime.add(DateTime.utc_now(), -3, :day))

      assert run_tool(h, "get_pantry", %{})["items"] == []
    end
  end
end
