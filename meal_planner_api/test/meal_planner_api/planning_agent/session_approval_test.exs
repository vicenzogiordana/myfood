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
end
