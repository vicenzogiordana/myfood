defmodule MealPlannerApi.PlanningAgent.SessionConfirmTest do
  @moduledoc """
  Confirm Proposal through the session module (issue #102, spec #93 user
  stories 71–77 and 90–93): only the Member's confirmation saves a plan, it
  appends the Purchase to the Shopping List without touching existing lines,
  and it is idempotent by its confirmation identity.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Planning.{PlanningSession, ScheduledMeal}
  alias MealPlannerApi.Persistence.Shopping.ShoppingItem
  alias MealPlannerApi.PlanningAgent.{Confirmation, FakeOptimizer, FlakyConfirmationStore, Tools}
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    pasta = ingredient!("Fictitious pasta")
    rice = ingredient!("Fictitious rice")

    recipe =
      recipe!("Pasta and rice", [pasta, rice],
        quantities: %{pasta.id => {100_000, :g}, rice.id => {200_000, :g}}
      )

    product!(pasta, name: "Fictitious penne", package: {500_000, :g}, price_cents: 1_000)
    product!(rice, name: "Fictitious rice 1 kg", package: {1_000_000, :g}, price_cents: 1_200)

    %{household: household, pasta: pasta, rice: rice, recipe: recipe}
  end

  # One day, lunch and dinner, both with `recipe`: the agent runs the
  # optimizer and presents the Proposal. `script` continues the conversation
  # for later turns.
  defp present!(household, recipe, opts \\ []) do
    script =
      [
        {:tool_calls, [{"run_optimizer", %{}}]},
        {:tool_calls, [{"present_proposal", %{}}]},
        {:text, "Here is your plan."}
      ] ++ Keyword.get(opts, :script, [])

    attrs = session_attrs(household, household.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(
        attrs,
        Keyword.merge(
          [
            model: {Scripted, script: script, notify: self()},
            optimizer: {FakeOptimizer, result: FakeOptimizer.everywhere(recipe.id)},
            subscriber: self()
          ],
          Keyword.get(opts, :session, [])
        )
      )

    :ok = Session.send_message(pid, "Plan Monday")
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}
    flush_model_requests()

    %{session_id: session_id, pid: pid, proposal: proposal}
  end

  # Every model request of a finished run is already in the mailbox.
  defp flush_model_requests do
    receive do
      {:scripted_model_request, _request} -> flush_model_requests()
    after
      0 -> :ok
    end
  end

  defp confirm(household, proposal_id),
    do: Session.confirm(household.account_id, household.owner.membership_id, proposal_id)

  defp planned_meals(household) do
    Repo.all(
      from(m in ScheduledMeal,
        where: m.account_id == ^household.account_id,
        order_by: [asc: m.date, asc: m.slot]
      )
    )
  end

  defp shopping_lines(household) do
    Repo.all(
      from(i in ShoppingItem,
        where: i.account_id == ^household.account_id,
        order_by: [asc: i.inserted_at]
      )
    )
  end

  # A pending and an in-cart Shopping List line of an earlier confirmed plan.
  defp existing_lines!(household, ingredient) do
    other = recipe!("Earlier stew", [ingredient])
    meal = scheduled_meal!(household, ~D[2026-10-26], :lunch, other)

    for status <- [:pending, :in_cart] do
      %ShoppingItem{}
      |> ShoppingItem.changeset(%{
        account_id: household.account_id,
        scheduled_meal_id: meal.id,
        planned_date: meal.date,
        ingredient_id: ingredient.id,
        quantity_milli: 123_000,
        unit: :g,
        status: status,
        estimated_price_cents: 456
      })
      |> Repo.insert!()
    end
  end

  describe "confirming the exact current Proposal" do
    test "saves the Planned Meals and appends the Purchase lines", %{household: h} = ctx do
      %{session_id: session_id, pid: pid, proposal: proposal} = present!(h, ctx.recipe)
      ref = Process.monitor(pid)

      assert {:ok, confirmation} = confirm(h, proposal["proposal_id"])
      assert confirmation.confirmation_id == proposal["proposal_id"]
      assert confirmation.meals_count == 2
      assert confirmation.shopping_lines_count == 2

      assert [
               %ScheduledMeal{date: @monday, slot: :lunch, is_cooked: false} = lunch,
               %ScheduledMeal{date: @monday, slot: :dinner} = dinner
             ] = planned_meals(h) |> Enum.sort_by(&(&1.slot != :lunch))

      assert lunch.recipe_id == ctx.recipe.id
      assert dinner.recipe_id == ctx.recipe.id

      # The Purchase shown is what lands on the Shopping List: one line per
      # Purchase line, pending, with its quantity and price.
      lines = shopping_lines(h)
      purchase = proposal["purchase"]["lines"]
      assert length(lines) == length(purchase)

      for shown <- purchase do
        ingredient = if shown["ingredient"] == ctx.pasta.name, do: ctx.pasta, else: ctx.rice
        line = Enum.find(lines, &(&1.ingredient_id == ingredient.id))

        assert line.status == :pending
        assert line.quantity_milli == shown["quantity_milli"]
        assert Atom.to_string(line.unit) == shown["unit"]
        assert line.estimated_price_cents == shown["total_cents"]
        assert line.planned_date == @monday
        assert line.scheduled_meal_id in [lunch.id, dinner.id]
      end

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal_confirmed", "proposal_id" => confirmed_id}}

      assert confirmed_id == proposal["proposal_id"]

      # The Planning Session is committed and the Household's slot released.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Repo.get!(PlanningSession, session_id).status == :committed
      assert Session.whereis(h.account_id) == nil
    end

    test "existing pending and in-cart Shopping List lines are untouched",
         %{household: h} = ctx do
      before = existing_lines!(h, ctx.pasta)
      %{proposal: proposal} = present!(h, ctx.recipe)

      assert {:ok, _} = confirm(h, proposal["proposal_id"])

      lines = shopping_lines(h)

      for line <- before do
        assert Enum.find(lines, &(&1.id == line.id)) == line
      end

      assert length(lines) == length(before) + length(proposal["purchase"]["lines"])
    end

    test "only the session's Member can confirm", %{household: h} = ctx do
      %{proposal: proposal} = present!(h, ctx.recipe)
      other = member!(h)

      assert {:error, :forbidden} =
               Session.confirm(h.account_id, other.membership_id, proposal["proposal_id"])

      assert planned_meals(h) == []
    end
  end

  describe "a stale Proposal" do
    test "a Proposal that is not the one on display is not saved and is shown again",
         %{household: h} = ctx do
      %{session_id: session_id, proposal: proposal} = present!(h, ctx.recipe)

      assert {:error, :stale_proposal} = confirm(h, Ecto.UUID.generate())

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = shown}
      assert shown["proposal_id"] == proposal["proposal_id"]
      assert planned_meals(h) == []
      assert shopping_lines(h) == []
    end

    test "a Projected Pantry change by another Member makes it stale and recalculates it",
         %{household: h} = ctx do
      %{session_id: session_id, proposal: proposal} = present!(h, ctx.recipe)

      # Another Member stocks enough rice for the plan meanwhile.
      pantry!(h, ctx.rice, 1_000_000)

      assert {:error, :stale_proposal} = confirm(h, proposal["proposal_id"])
      assert planned_meals(h) == []
      assert shopping_lines(h) == []

      # The Member is asked again with a recalculated Proposal: same meals,
      # a new identity and the Purchase net of the new stock.
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = recalculated}
      refute recalculated["proposal_id"] == proposal["proposal_id"]
      assert recalculated["meals"] == proposal["meals"]
      assert [%{"ingredient" => pasta}] = recalculated["purchase"]["lines"]
      assert pasta == ctx.pasta.name

      # The earlier identity stays stale; the recalculated one confirms.
      assert {:error, :stale_proposal} = confirm(h, proposal["proposal_id"])
      assert {:ok, %{shopping_lines_count: 1}} = confirm(h, recalculated["proposal_id"])
      assert length(planned_meals(h)) == 2
    end

    test "a budget change makes it stale and the recalculated Proposal needs approval",
         %{household: h} = ctx do
      %{session_id: session_id, proposal: proposal} = present!(h, ctx.recipe)
      assert proposal["status"] == "valid"

      budget!(h, 100)

      assert {:error, :stale_proposal} = confirm(h, proposal["proposal_id"])

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal", "status" => "requires_approval"} = recalculated}

      assert [%{"type" => "budget", "budget_cents" => 100}] = recalculated["deviations"]

      # Deviation Approval is a separate human action (#103): until it is
      # given, a Proposal with Deviations cannot be confirmed.
      assert {:error, :approval_required} = confirm(h, recalculated["proposal_id"])
      assert planned_meals(h) == []
    end
  end

  describe "a revalidation conflict" do
    test "blocks saving and leads to a corrected Proposal needing new confirmation",
         %{household: h} do
      peanut = ingredient!("Fictitious peanut")
      risky = recipe!("Peanut noodles", [peanut])
      safe = recipe!("Plain noodles", [ingredient!("Fictitious noodle")])

      # The optimizer prefers the peanut recipe whenever it is a candidate.
      prefer_risky = fn payload ->
        meals =
          for day <- payload["days"], slot <- payload["slots"] do
            ids = Enum.map(payload["candidates_by_slot"][slot], & &1["recipe_id"])
            id = if risky.id in ids, do: risky.id, else: safe.id
            %{"day" => day, "slot" => slot, "recipe_id" => id}
          end

        {:ok, %{"meals" => meals}}
      end

      %{session_id: session_id, proposal: proposal} =
        present!(h, risky,
          session: [optimizer: {FakeOptimizer, result: prefer_risky}],
          script: [
            {:tool_calls, [{"run_optimizer", %{}}]},
            {:tool_calls, [{"present_proposal", %{}}]},
            {:text, "Here is a corrected plan."}
          ]
        )

      assert Enum.all?(proposal["meals"], &(&1["recipe_id"] == risky.id))

      # Another Member with a peanut allergy joins meanwhile.
      h |> member!() |> allergy!(peanut)

      assert {:error, :revalidation_conflict} = confirm(h, proposal["proposal_id"])
      assert planned_meals(h) == []
      assert shopping_lines(h) == []

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal_invalidated", "reason" => "revalidation_conflict"} =
                        invalidated}

      assert invalidated["proposal_id"] == proposal["proposal_id"]
      assert [%{"type" => "restriction_conflict"} | _] = invalidated["violations"]

      # The agent is told why and builds a corrected Proposal, with a new
      # identity that needs the Member's confirmation.
      assert_receive {:scripted_model_request, %{messages: messages}}
      assert %{role: :user, content: notice} = List.last(messages)
      assert notice =~ "restriction_conflict"

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = corrected}
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}
      refute corrected["proposal_id"] == proposal["proposal_id"]
      assert Enum.all?(corrected["meals"], &(&1["recipe_id"] == safe.id))
      assert planned_meals(h) == []

      assert {:error, :stale_proposal} = confirm(h, proposal["proposal_id"])
      assert {:ok, %{meals_count: 2}} = confirm(h, corrected["proposal_id"])
      assert Enum.all?(planned_meals(h), &(&1.recipe_id == safe.id))
    end
  end

  describe "idempotent confirmation" do
    test "replaying the same confirmation never saves twice", %{household: h} = ctx do
      %{pid: pid, proposal: proposal} = present!(h, ctx.recipe)
      ref = Process.monitor(pid)

      assert {:ok, first} = confirm(h, proposal["proposal_id"])
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      # The Planning Session and its Workspace are gone; the confirmation
      # identity outlives them.
      assert {:ok, ^first} = confirm(h, proposal["proposal_id"])
      assert length(planned_meals(h)) == 2
      assert length(shopping_lines(h)) == first.shopping_lines_count
    end

    test "replaying a confirmation from an ended session leaves the next session running",
         %{household: h} = ctx do
      %{pid: first_pid, proposal: proposal} = present!(h, ctx.recipe)
      ref = Process.monitor(first_pid)

      assert {:ok, summary} = confirm(h, proposal["proposal_id"])
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :normal}

      tuesday = Date.add(@monday, 1)

      {:ok, %{session_id: session_id, pid: pid}} =
        Session.start(session_attrs(h, h.owner, {tuesday, tuesday}),
          model: {Scripted, script: []},
          subscriber: self()
        )

      # A late retry of the first Proposal reaches the Household's new session.
      assert {:ok, ^summary} = confirm(h, proposal["proposal_id"])

      assert Process.alive?(pid)
      assert Session.info(pid).session_id == session_id
      refute_received {:planning_agent_event, ^session_id, %{"type" => "proposal_confirmed"}}
      refute_received {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}
      assert Repo.get!(PlanningSession, session_id).status == :active
      assert length(planned_meals(h)) == 2
    end

    test "concurrent confirmations of the same Proposal save once", %{household: h} = ctx do
      %{proposal: proposal} = present!(h, ctx.recipe)

      results =
        1..3
        |> Enum.map(fn _ -> Task.async(fn -> confirm(h, proposal["proposal_id"]) end) end)
        |> Task.await_many(10_000)

      assert [{:ok, summary}, {:ok, summary}, {:ok, summary}] = results
      assert length(planned_meals(h)) == 2
      assert length(shopping_lines(h)) == summary.shopping_lines_count
    end

    test "the status of a confirmation stays queryable", %{household: h} = ctx do
      %{proposal: proposal} = present!(h, ctx.recipe)
      assert Session.confirmation_status(h.account_id, proposal["proposal_id"]) == :not_found

      assert {:ok, summary} = confirm(h, proposal["proposal_id"])

      assert Session.confirmation_status(h.account_id, proposal["proposal_id"]) ==
               {:confirmed, summary}

      # Another Household never sees it.
      assert Session.confirmation_status(household!().account_id, proposal["proposal_id"]) ==
               :not_found
    end
  end

  describe "a lost acknowledgement" do
    test "is reconciled without saving twice", %{household: h} = ctx do
      %{session_id: session_id, proposal: proposal} =
        present!(h, ctx.recipe,
          session: [
            confirmation_store: {FlakyConfirmationStore, mode: :lost_ack, notify: self()},
            poll_ms: 10
          ]
        )

      assert {:ok, %{meals_count: 2}} = confirm(h, proposal["proposal_id"])
      assert_received {:confirmation_store, :commit}
      refute_received {:confirmation_store, :commit}

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal_confirmed"}}
      assert length(planned_meals(h)) == 2
    end

    test "an unverifiable confirmation is unresolved after the window, never failed",
         %{household: h} = ctx do
      window_ms = 200

      %{session_id: session_id, pid: pid, proposal: proposal} =
        present!(h, ctx.recipe,
          session: [
            confirmation_store: {FlakyConfirmationStore, mode: :unreachable},
            reconcile_ms: window_ms,
            poll_ms: 20
          ]
        )

      started = System.monotonic_time(:millisecond)
      assert {:error, :unresolved} = confirm(h, proposal["proposal_id"])
      assert System.monotonic_time(:millisecond) - started >= window_ms

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "confirmation_unresolved", "proposal_id" => unresolved}}

      assert unresolved == proposal["proposal_id"]
      refute_received {:planning_agent_event, ^session_id, %{"type" => "agent_unavailable"}}

      # The session keeps the Proposal and the status stays queryable.
      assert Session.whereis(h.account_id) == pid
      assert Session.confirmation_status(h.account_id, proposal["proposal_id"]) == :not_found
    end

    test "is reconciled for up to 30 seconds by default" do
      assert Confirmation.reconcile_window_ms() == 30_000
    end
  end

  describe "the agent cannot persist a plan" do
    test "no tool saves a plan or edits the Shopping List" do
      names = Enum.map(Tools.definitions(), & &1.name)

      refute Enum.any?(names, &String.contains?(&1, ["confirm", "save", "shopping", "approve"]))
    end

    test "presenting a Proposal and calling unknown save tools saves nothing",
         %{household: h} = ctx do
      %{session_id: session_id, pid: pid} =
        present!(h, ctx.recipe,
          script: [
            {:tool_calls,
             [{"confirm_proposal", %{}}, {"save_plan", %{}}, {"edit_shopping_list", %{}}]},
            {:text, "I cannot save plans."}
          ]
        )

      :ok = Session.send_message(pid, "Save it for me")
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}

      assert planned_meals(h) == []
      assert shopping_lines(h) == []
    end
  end
end
