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
  alias MealPlannerApi.PlanningAgent.{FakeOptimizer, Tools}
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

    %{session_id: session_id, pid: pid, proposal: proposal}
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
