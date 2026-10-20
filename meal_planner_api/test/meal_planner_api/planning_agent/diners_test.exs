defmodule MealPlannerApi.PlanningAgent.DinersTest do
  @moduledoc """
  Planned Meals scaled to their diners, with guests (issue #152, spec #93),
  through the session module with the scripted model and a fake optimizer.

  The diners of a meal are the Household Members present (minus approved
  Absence Exceptions) plus that meal's guests; each meal buys
  ceil(diners / recipe servings) batches of its recipe.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.PlanningAgent.{FakeOptimizer, HouseholdContext, ProposalValidator, Tools}
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]
  @now ~U[2026-10-14 12:00:00.000000Z]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    pasta = ingredient!("Fictitious pasta")
    # A 2-serving recipe with 100 g of pasta per batch.
    recipe = recipe!("Fictitious pasta bake", [pasta], quantities: %{pasta.id => {100_000, :g}})
    # 1 kg of pasta costs 1_000 cents.
    product!(pasta, name: "Fictitious penne 1 kg", package: {1_000_000, :g}, price_cents: 1_000)

    %{household: household, pasta: pasta, recipe: recipe}
  end

  defp start!(household, script, opts) do
    range = Keyword.get(opts, :range, {@monday, @monday})
    slots = Keyword.get(opts, :slots, ["lunch"])
    attrs = session_attrs(household, household.owner, range, slots)

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, [notify: self()] ++ Keyword.take(opts, [:result])},
        clock: fn -> @now end,
        subscriber: self()
      )

    {session_id, pid}
  end

  # Sends `text` and returns every tool result of the turn, in order.
  defp turn!(session_id, pid, text) do
    :ok = Session.send_message(pid, text)
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}

    nil
    |> drain_requests()
    |> List.wrap()
    |> Enum.filter(&(&1.role == :tool_result))
    |> Enum.map(& &1.content)
  end

  defp drain_requests(last) do
    receive do
      {:scripted_model_request, %{messages: messages}} -> drain_requests(messages)
    after
      0 -> last
    end
  end

  defp plan_script(edits \\ []) do
    Enum.map(edits, &{:tool_calls, [{"edit_workspace", &1}]}) ++
      [
        {:tool_calls, [{"run_optimizer", %{}}]},
        {:tool_calls, [{"present_proposal", %{}}]},
        {:text, "Here is your plan."}
      ]
  end

  defp proposal!(session_id) do
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}
    proposal
  end

  defp meal(proposal, date, slot),
    do:
      Enum.find(proposal["meals"], &(&1["date"] == Date.to_iso8601(date) and &1["slot"] == slot))

  defp pasta_line(proposal, pasta),
    do: Enum.find(proposal["purchase"]["lines"], &(&1["ingredient"] == pasta.name))

  defp three_members!(household) do
    a = member!(household)
    b = member!(household)
    [a, b]
  end

  describe "scaling to the Household" do
    test "a 2-serving recipe for a 3-member Household buys 2 batches",
         %{household: h, pasta: pasta, recipe: recipe} do
      three_members!(h)
      {session_id, pid} = start!(h, plan_script(), result: FakeOptimizer.everywhere(recipe.id))

      _ = turn!(session_id, pid, "Plan Monday lunch")
      proposal = proposal!(session_id)

      assert %{"diners" => 3, "guests" => 0, "batches" => 2} = meal(proposal, @monday, "lunch")
      # ceil(3 / 2) = 2 batches of 100 g.
      assert %{"quantity_milli" => 200_000, "packages" => 1} = pasta_line(proposal, pasta)
      # 200 g at 1_000 per kg.
      assert proposal["consumed_cost"]["total_cents"] == 200
    end

    test "a single-member Household still buys one batch",
         %{household: h, pasta: pasta, recipe: recipe} do
      {session_id, pid} = start!(h, plan_script(), result: FakeOptimizer.everywhere(recipe.id))

      _ = turn!(session_id, pid, "Plan Monday lunch")
      proposal = proposal!(session_id)

      assert %{"diners" => 1, "batches" => 1} = meal(proposal, @monday, "lunch")
      assert %{"quantity_milli" => 100_000} = pasta_line(proposal, pasta)
    end

    test "an Absence Exception reduces the diners of the meals it covers",
         %{household: h, pasta: pasta, recipe: recipe} do
      [vegetarian, _other] = three_members!(h)
      diet!(vegetarian, :vegetarian)

      {session_id, pid} =
        start!(h, plan_script(),
          slots: ["lunch", "dinner"],
          result: FakeOptimizer.everywhere(recipe.id)
        )

      assert :ok =
               Session.approve_absence_exception(h.account_id, h.owner.membership_id, %{
                 member_id: vegetarian.user_id,
                 restriction: {:diet, :vegetarian},
                 meals: [{@monday, "lunch"}]
               })

      _ = turn!(session_id, pid, "Plan Monday")
      proposal = proposal!(session_id)

      assert %{"diners" => 2, "batches" => 1} = meal(proposal, @monday, "lunch")
      assert %{"diners" => 3, "batches" => 2} = meal(proposal, @monday, "dinner")
      # 1 + 2 batches of 100 g.
      assert %{"quantity_milli" => 300_000} = pasta_line(proposal, pasta)
    end
  end

  describe "guests" do
    test "6 guests on Tuesday lunch scale that meal to 9 diners",
         %{household: h, pasta: pasta, recipe: recipe} do
      three_members!(h)

      script =
        plan_script([
          %{"action" => "set_guests", "date" => "2026-11-03", "slot" => "lunch", "guests" => 6}
        ])

      {session_id, pid} =
        start!(h, script, range: {@monday, @tuesday}, result: FakeOptimizer.everywhere(recipe.id))

      [edit, _run, present] = turn!(session_id, pid, "Burgers on Tuesday lunch with 6 friends")
      proposal = proposal!(session_id)

      assert %{"status" => "ok", "guests" => %{"date" => "2026-11-03", "slot" => "lunch"}} =
               edit

      assert %{"diners" => 3, "guests" => 0, "batches" => 2} = meal(proposal, @monday, "lunch")
      assert %{"diners" => 9, "guests" => 6, "batches" => 5} = meal(proposal, @tuesday, "lunch")
      # 2 + 5 batches of 100 g: 700 g in one 1 kg package.
      assert %{"quantity_milli" => 700_000, "packages" => 1} = pasta_line(proposal, pasta)
      assert present["consumed_cost_cents"] == 700
    end

    test "guest cost over the budget is an ordinary budget Deviation, approved as usual",
         %{household: h, recipe: recipe} do
      # One batch (100 g) fits; the 6 guests need 4 batches, 400 g: still one
      # package. A 300 g package forces a second one.
      budget!(h, 1_000)
      bigger = ingredient!("Fictitious rice")

      rice_pot =
        recipe!("Fictitious rice pot", [bigger], quantities: %{bigger.id => {100_000, :g}})

      product!(bigger, name: "Fictitious rice 300 g", package: {300_000, :g}, price_cents: 600)

      script =
        plan_script([
          %{"action" => "set_guests", "date" => "2026-11-02", "slot" => "lunch", "guests" => 6}
        ])

      {session_id, pid} = start!(h, script, result: FakeOptimizer.everywhere(rice_pot.id))
      [_edit, _run, present] = turn!(session_id, pid, "Monday lunch, 6 friends are coming")
      proposal = proposal!(session_id)

      # 7 diners: ceil(7 / 2) = 4 batches = 400 g = 2 packages of 300 g.
      assert proposal["status"] == "requires_approval"

      assert [%{"type" => "budget", "total_cents" => 1_200, "difference_cents" => 200}] =
               proposal["deviations"]

      assert present["status"] == "requires_approval"

      assert {:error, :approval_required} =
               Session.confirm(h.account_id, h.owner.membership_id, proposal["proposal_id"])

      assert :ok =
               Session.approve_deviations(
                 h.account_id,
                 h.owner.membership_id,
                 proposal["proposal_id"]
               )

      assert {:ok, _summary} =
               Session.confirm(h.account_id, h.owner.membership_id, proposal["proposal_id"])

      _ = recipe
    end

    test "confirmed Planned Meals store their diners, guests and batches",
         %{household: h, recipe: recipe} do
      three_members!(h)

      script =
        plan_script([
          %{"action" => "set_guests", "date" => "2026-11-03", "slot" => "lunch", "guests" => 6}
        ])

      {session_id, pid} =
        start!(h, script, range: {@monday, @tuesday}, result: FakeOptimizer.everywhere(recipe.id))

      _ = turn!(session_id, pid, "Tuesday lunch with 6 friends")
      proposal = proposal!(session_id)

      assert {:ok, _summary} =
               Session.confirm(h.account_id, h.owner.membership_id, proposal["proposal_id"])

      stored =
        Repo.all(
          from(m in ScheduledMeal,
            where: m.account_id == ^h.account_id,
            order_by: m.date,
            select: {m.date, m.diners, m.guests, m.selected_quantity}
          )
        )

      assert stored == [{@monday, 3, 0, 2}, {@tuesday, 9, 6, 5}]
    end

    test "set_guests refuses invalid counts and restrictions", %{household: h} do
      script = [
        {:tool_calls,
         [
           {"edit_workspace",
            %{"action" => "set_guests", "date" => "2026-11-02", "slot" => "lunch", "guests" => -1}},
           {"edit_workspace",
            %{
              "action" => "set_guests",
              "date" => "2026-11-02",
              "slot" => "lunch",
              "guests" => 2,
              "guest_restrictions" => ["moon dust"]
            }},
           {"edit_workspace",
            %{
              "action" => "set_guests",
              "date" => "2026-11-02",
              "slot" => "lunch",
              "guests" => 0,
              "guest_restrictions" => ["peanut"]
            }}
         ]},
        {:text, "done"}
      ]

      {session_id, pid} = start!(h, script, [])

      assert [
               %{"error" => "invalid_guests"},
               %{"error" => "invalid_guest_restriction"},
               %{"error" => "guest_restrictions_need_guests"}
             ] = turn!(session_id, pid, "Go")
    end
  end

  describe "guest restrictions" do
    setup %{household: h} do
      peanut = ingredient!("Fictitious peanut", [:peanut])
      satay = recipe!("Fictitious satay", [peanut])
      product!(peanut, name: "Fictitious peanuts", package: {1_000_000, :g}, price_cents: 500)
      _ = h
      %{satay: satay}
    end

    test "a guest allergy excludes conflicting recipes for that meal only",
         %{household: h, satay: satay} do
      script =
        plan_script([
          %{
            "action" => "set_guests",
            "date" => "2026-11-02",
            "slot" => "lunch",
            "guests" => 2,
            "guest_restrictions" => ["peanut"]
          }
        ])

      {session_id, pid} =
        start!(h, script, slots: ["lunch", "dinner"], result: FakeOptimizer.everywhere(satay.id))

      [_edit, run, present] =
        turn!(session_id, pid, "Two friends for lunch, one is allergic to peanuts")

      # The optimizer is told to avoid the conflicting recipe at that meal only.
      assert_receive {:optimizer_payload, payload}

      assert %{"day" => "2026-11-02", "slot" => "lunch", "recipe_id" => satay.id} in payload[
               "avoided_meals"
             ]

      refute Enum.any?(payload["avoided_meals"], &(&1["slot"] == "dinner"))

      # Code, not the optimizer's word, refuses a plan serving it there anyway.
      assert %{"error" => "optimizer_failed", "reason" => "released_meal_unchanged"} = run
      assert %{"error" => "no_plan_to_present"} = present
      refute_received {:planning_agent_event, ^session_id, %{"type" => "proposal"}}
    end

    test "the Household is unchanged: other meals may still use the recipe",
         %{household: h, recipe: recipe, satay: satay} do
      script =
        plan_script([
          %{
            "action" => "set_guests",
            "date" => "2026-11-02",
            "slot" => "lunch",
            "guests" => 1,
            "guest_restrictions" => ["peanut"]
          }
        ])

      result = fn payload ->
        meals =
          for day <- payload["days"], slot <- payload["slots"] do
            id = if slot == "lunch", do: recipe.id, else: satay.id
            %{"day" => day, "slot" => slot, "recipe_id" => id}
          end

        {:ok, %{"meals" => meals}}
      end

      {session_id, pid} = start!(h, script, slots: ["lunch", "dinner"], result: result)
      [_edit, _run, present] = turn!(session_id, pid, "A friend allergic to peanuts joins lunch")

      assert present["status"] == "valid"
      proposal = proposal!(session_id)
      assert %{"recipe_id" => satay_id, "diners" => 1} = meal(proposal, @monday, "dinner")
      assert satay_id == satay.id
      assert %{"diners" => 2, "guests" => 1} = meal(proposal, @monday, "lunch")
      assert HouseholdContext.load(h.account_id, h.owner.user_id).forbidden_tags == MapSet.new()
    end

    test "a Pin conflicting with a guest restriction is refused",
         %{household: h, satay: satay} do
      script = [
        {:tool_calls,
         [
           {"edit_workspace",
            %{
              "action" => "set_guests",
              "date" => "2026-11-02",
              "slot" => "lunch",
              "guests" => 1,
              "guest_restrictions" => ["peanut"]
            }}
         ]},
        {:tool_calls,
         [
           {"edit_workspace",
            %{
              "action" => "pin",
              "date" => "2026-11-02",
              "slot" => "lunch",
              "recipe_id" => satay.id
            }}
         ]},
        {:text, "done"}
      ]

      {session_id, pid} = start!(h, script, [])

      assert [%{"status" => "ok"}, %{"error" => "restriction_conflict"}] =
               turn!(session_id, pid, "Pin satay for lunch")
    end
  end

  describe "guest restrictions in the validator" do
    test "a plan serving a guest's allergen at that meal is invalid; other meals are not",
         %{household: h} do
      peanut = ingredient!("Fictitious peanut", [:peanut])
      satay = recipe!("Fictitious satay", [peanut])

      ctx = %{
        account_id: h.account_id,
        range: {@monday, @monday},
        slots: ["lunch", "dinner"],
        household: HouseholdContext.load(h.account_id, h.owner.user_id),
        guests: %{{@monday, "lunch"} => %{count: 1, restrictions: [{:allergy, :peanut}]}}
      }

      meals = [
        %{date: @monday, slot: "lunch", recipe_id: satay.id},
        %{date: @monday, slot: "dinner", recipe_id: satay.id}
      ]

      assert {:invalid, [%{"type" => "restriction_conflict", "slot" => "lunch"} = violation]} =
               ProposalValidator.validate(meals, ctx)

      assert violation["message"] =~ "guest"

      assert {:valid, _meals} = ProposalValidator.validate(meals, Map.put(ctx, :guests, %{}))
    end
  end

  describe "low friction" do
    test "the instructions say to set guests and never ask about guest restrictions",
         %{household: h} do
      member!(h)
      context = HouseholdContext.load(h.account_id, h.owner.user_id)
      text = HouseholdContext.instructions(context, {@monday, @tuesday}, ["lunch"])

      assert text =~ "Household Members: 2"
      assert text =~ "set_guests"
      assert text =~ "Never ask whether guests have allergies"
      refute text =~ "more people than the household"

      %{description: description, parameters: parameters} =
        Enum.find(Tools.definitions(), &(&1.name == "edit_workspace"))

      assert "set_guests" in parameters["properties"]["action"]["enum"]
      assert description =~ "never ask"
    end

    test "a guest request is planned and presented without any question",
         %{household: h, recipe: recipe} do
      three_members!(h)

      script =
        plan_script([
          %{"action" => "set_guests", "date" => "2026-11-03", "slot" => "lunch", "guests" => 6}
        ])

      {session_id, pid} =
        start!(h, script, range: {@monday, @tuesday}, result: FakeOptimizer.everywhere(recipe.id))

      _ = turn!(session_id, pid, "Burgers on Tuesday lunch with 6 friends")

      assert %{"meals" => meals} = proposal!(session_id)
      assert Enum.any?(meals, &(&1["diners"] == 9))
      refute_received {:planning_agent_event, ^session_id, %{"type" => "question"}}
    end
  end
end
