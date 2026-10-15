defmodule MealPlannerApi.PlanningAgent.SessionApprovalTest do
  @moduledoc """
  Deviation Approval and Absence Exception through the session module
  (issue #103, spec #93 user stories 11, 17 and 62–67): both are human-only
  actions the agent can only ask for. A Deviation Approval accepts every
  Deviation of one exact Proposal; an Absence Exception lifts one
  Restriction of one Member for specific Planned Meals.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.NutritionGoals
  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @goal %{
    "calories" => %{"min" => 1800, "max" => 2200},
    "protein_g" => %{"min" => 60, "max" => 120},
    "carbs_g" => %{"min" => 150, "max" => 300},
    "fat_g" => %{"min" => 40, "max" => 80}
  }

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

    # The Purchase of one day (lunch and dinner) costs 2_200 cents.
    product!(pasta, name: "Fictitious penne", package: {500_000, :g}, price_cents: 1_000)
    product!(rice, name: "Fictitious rice 1 kg", package: {1_000_000, :g}, price_cents: 1_200)

    %{household: household, recipe: recipe}
  end

  # One day, lunch and dinner, planned with `optimizer_result`. `script`
  # continues the conversation for later turns.
  defp present!(household, optimizer_result, opts \\ []) do
    script =
      [
        {:tool_calls, [{"run_optimizer", %{}}]},
        {:tool_calls, [{"present_proposal", %{}}]},
        {:text, "Here is your plan."}
      ] ++ Keyword.get(opts, :script, [])

    attrs = session_attrs(household, household.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, result: optimizer_result},
        subscriber: self()
      )

    :ok = Session.send_message(pid, "Plan Monday")
    proposal = await_proposal(session_id)

    %{session_id: session_id, pid: pid, proposal: proposal}
  end

  defp await_proposal(session_id) do
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}
    proposal
  end

  defp approve(household, proposal_id),
    do:
      Session.approve_deviations(household.account_id, household.owner.membership_id, proposal_id)

  defp confirm(household, proposal_id),
    do: Session.confirm(household.account_id, household.owner.membership_id, proposal_id)

  defp planned_meals(household) do
    Repo.all(from(m in ScheduledMeal, where: m.account_id == ^household.account_id))
  end

  defp stored_budget(household), do: Repo.get!(Account, household.account_id).default_budget_cents

  describe "Deviation Approval" do
    test "a Proposal requiring approval is confirmed only after its Deviation Approval",
         %{household: h, recipe: recipe} do
      budget!(h, 100)
      {:ok, _} = NutritionGoals.put(h.account_id, @goal)
      goal_before = NutritionGoals.get(h.account_id)

      %{session_id: session_id, proposal: proposal} =
        present!(h, FakeOptimizer.everywhere(recipe.id))

      assert proposal["status"] == "requires_approval"
      assert [%{"type" => "budget", "difference_cents" => 2_100}] = proposal["deviations"]

      assert {:error, :approval_required} = confirm(h, proposal["proposal_id"])
      assert planned_meals(h) == []

      assert :ok = approve(h, proposal["proposal_id"])

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "deviations_approved"} = approved}

      assert approved["proposal_id"] == proposal["proposal_id"]
      assert approved["deviations"] == proposal["deviations"]

      # Approving never changes the stored budget or Nutrition Goal.
      assert stored_budget(h) == 100
      assert NutritionGoals.get(h.account_id) == goal_before

      assert {:ok, %{meals_count: 2}} = confirm(h, proposal["proposal_id"])
      assert length(planned_meals(h)) == 2

      assert stored_budget(h) == 100
      assert NutritionGoals.get(h.account_id) == goal_before
    end

    test "only the exact current Proposal with Deviations can be approved",
         %{household: h, recipe: recipe} do
      %{proposal: valid} = present!(h, FakeOptimizer.everywhere(recipe.id))
      assert valid["status"] == "valid"

      assert {:error, :no_deviations} = approve(h, valid["proposal_id"])
      assert {:error, :stale_proposal} = approve(h, Ecto.UUID.generate())

      other = member!(h)

      assert {:error, :forbidden} =
               Session.approve_deviations(h.account_id, other.membership_id, valid["proposal_id"])
    end

    test "without a Planning Session nothing can be approved", %{household: h} do
      assert {:error, :session_not_active} = approve(h, Ecto.UUID.generate())
    end

    test "a new Proposal from the agent voids the approval", %{household: h, recipe: recipe} do
      budget!(h, 100)

      %{session_id: session_id, pid: pid, proposal: first} =
        present!(h, FakeOptimizer.everywhere(recipe.id),
          script: [
            {:tool_calls, [{"run_optimizer", %{}}]},
            {:tool_calls, [{"present_proposal", %{}}]},
            {:text, "Here it is again."}
          ]
        )

      assert :ok = approve(h, first["proposal_id"])

      :ok = Session.send_message(pid, "Show it again")
      second = await_proposal(session_id)

      # Same meals and Deviations, but another Proposal: the approval of the
      # first one does not cover it.
      refute second["proposal_id"] == first["proposal_id"]
      assert second["deviations"] == first["deviations"]

      assert {:error, :approval_required} = confirm(h, second["proposal_id"])
      assert {:error, :stale_proposal} = confirm(h, first["proposal_id"])
      assert planned_meals(h) == []

      assert :ok = approve(h, second["proposal_id"])
      assert {:ok, _} = confirm(h, second["proposal_id"])
    end

    test "a Proposal recalculated at confirmation needs a new approval",
         %{household: h, recipe: recipe} do
      budget!(h, 100)

      %{session_id: session_id, proposal: proposal} =
        present!(h, FakeOptimizer.everywhere(recipe.id))

      assert :ok = approve(h, proposal["proposal_id"])

      # The spend difference changes: the approved Proposal is stale.
      budget!(h, 150)

      assert {:error, :stale_proposal} = confirm(h, proposal["proposal_id"])

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal", "status" => "requires_approval"} = recalculated}

      assert [%{"difference_cents" => 2_050}] = recalculated["deviations"]
      assert {:error, :approval_required} = confirm(h, recalculated["proposal_id"])
      assert planned_meals(h) == []

      assert :ok = approve(h, recalculated["proposal_id"])
      assert {:ok, _} = confirm(h, recalculated["proposal_id"])
    end
  end

  describe "Absence Exception" do
    setup %{household: h} do
      beef = ingredient!("Fictitious beef", [:contains_meat])
      stew = recipe!("Beef stew", [beef])
      vegetarian = member!(h)
      diet!(vegetarian, :vegetarian)

      %{stew: stew, vegetarian: vegetarian}
    end

    # A session planning the beef stew for Monday lunch and dinner; every
    # later turn presents the same draft again.
    defp start_stew!(household, stew, turns) do
      script =
        [
          {:tool_calls, [{"run_optimizer", %{}}]},
          {:tool_calls, [{"present_proposal", %{}}]},
          {:text, "Here is your plan."}
        ] ++
          Enum.flat_map(1..turns//1, fn _ ->
            [{:tool_calls, [{"present_proposal", %{}}]}, {:text, "Presented again."}]
          end)

      attrs = session_attrs(household, household.owner, {@monday, @monday})

      {:ok, %{session_id: session_id, pid: pid}} =
        Session.start(attrs,
          model: {Scripted, script: script, notify: self()},
          optimizer: {FakeOptimizer, result: FakeOptimizer.everywhere(stew.id)},
          subscriber: self()
        )

      {session_id, pid}
    end

    # Runs one turn and returns the result of its last tool call.
    defp turn!(session_id, pid, text) do
      :ok = Session.send_message(pid, text)
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}

      nil
      |> drain_requests()
      |> Enum.filter(&(&1.role == :tool_result))
      |> List.last()
      |> Map.fetch!(:content)
    end

    defp drain_requests(last) do
      receive do
        {:scripted_model_request, %{messages: messages}} -> drain_requests(messages)
      after
        0 -> last
      end
    end

    defp approve_absence(household, exception),
      do:
        Session.approve_absence_exception(
          household.account_id,
          household.owner.membership_id,
          exception
        )

    defp lift(member, restriction, slots),
      do: %{
        member_id: member.user_id,
        restriction: restriction,
        meals: for(s <- slots, do: {@monday, s})
      }

    test "lets the validator accept exactly the approved meals",
         %{household: h, stew: stew, vegetarian: vegetarian} do
      {session_id, pid} = start_stew!(h, stew, 2)

      first = turn!(session_id, pid, "Plan Monday")
      assert first["status"] == "invalid"
      assert Enum.map(first["violations"], & &1["slot"]) |> Enum.sort() == ["dinner", "lunch"]

      # The vegetarian Member is away at Monday lunch only.
      assert :ok = approve_absence(h, lift(vegetarian, {:diet, :vegetarian}, ["lunch"]))

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "absence_exception_approved"} = approved}

      # Generic: the event names the meals, never the Member or Restriction.
      assert approved["meals"] == [%{"date" => "2026-11-02", "slot" => "lunch"}]
      refute Map.has_key?(approved, "member_id")

      second = turn!(session_id, pid, "Present it again")
      assert second["status"] == "invalid"

      assert [%{"type" => "restriction_conflict", "slot" => "dinner"}] = second["violations"]
      refute_received {:planning_agent_event, ^session_id, %{"type" => "proposal"}}

      assert :ok = approve_absence(h, lift(vegetarian, {:diet, :vegetarian}, ["dinner"]))
      third = turn!(session_id, pid, "Present it again")
      assert third["status"] == "valid"

      assert_received {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}

      # Confirmation revalidates with the same Absence Exceptions; the
      # Member's profile is never edited.
      assert {:ok, %{meals_count: 2}} = confirm(h, proposal["proposal_id"])

      assert [%{diet_type: :vegetarian}] =
               Repo.all(
                 from(p in MealPlannerApi.Persistence.Accounts.UserDietaryProfile,
                   where: p.user_id == ^vegetarian.user_id
                 )
               )
    end

    test "lifts an allergy, including the allergic ingredient itself", %{household: h} do
      peanut = ingredient!("Fictitious peanut", [:peanut])
      noodles = recipe!("Peanut noodles", [peanut])
      allergic = member!(h)
      allergy!(allergic, peanut)

      {session_id, pid} = start_stew!(h, noodles, 1)
      assert %{"status" => "invalid"} = turn!(session_id, pid, "Plan Monday")

      assert :ok =
               approve_absence(h, lift(allergic, {:allergy, :peanut}, ["lunch", "dinner"]))

      assert %{"status" => "valid"} = turn!(session_id, pid, "Present it again")
    end

    test "only lifts the named Restriction of the named Member",
         %{household: h, stew: stew, vegetarian: vegetarian} do
      # A second vegetarian Member stays at the table.
      h |> member!() |> diet!(:vegetarian)

      {session_id, pid} = start_stew!(h, stew, 1)
      assert %{"status" => "invalid"} = turn!(session_id, pid, "Plan Monday")

      assert :ok =
               approve_absence(h, lift(vegetarian, {:diet, :vegetarian}, ["lunch", "dinner"]))

      assert %{"status" => "invalid", "violations" => [_, _]} =
               turn!(session_id, pid, "Present it again")
    end

    test "is refused unless it names a Restriction a Member holds, for meals of the range",
         %{household: h, stew: stew, vegetarian: vegetarian} do
      {_session_id, _pid} = start_stew!(h, stew, 0)

      invalid = [
        lift(vegetarian, {:diet, :vegan}, ["lunch"]),
        lift(vegetarian, {:allergy, :peanut}, ["lunch"]),
        %{lift(vegetarian, {:diet, :vegetarian}, []) | meals: []},
        %{lift(vegetarian, {:diet, :vegetarian}, ["lunch"]) | member_id: Ecto.UUID.generate()},
        %{lift(vegetarian, {:diet, :vegetarian}, ["lunch"]) | meals: [{~D[2026-11-03], "lunch"}]},
        lift(vegetarian, {:diet, :vegetarian}, ["breakfast"]),
        %{member_id: vegetarian.user_id}
      ]

      for exception <- invalid do
        assert {:error, :invalid_absence_exception} = approve_absence(h, exception)
      end

      other = member!(h)

      assert {:error, :forbidden} =
               Session.approve_absence_exception(
                 h.account_id,
                 other.membership_id,
                 lift(vegetarian, {:diet, :vegetarian}, ["lunch"])
               )
    end

    test "without a Planning Session nothing can be approved",
         %{household: h, vegetarian: vegetarian} do
      assert {:error, :session_not_active} =
               approve_absence(h, lift(vegetarian, {:diet, :vegetarian}, ["lunch"]))
    end
  end
end
