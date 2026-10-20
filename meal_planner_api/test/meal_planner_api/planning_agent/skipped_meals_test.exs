defmodule MealPlannerApi.PlanningAgent.SkippedMealsTest do
  @moduledoc """
  Skipped meals (issue #160, spec #93): the Household says it will not eat
  at home at one day and slot ("Wednesday night we eat out"), and the agent
  skips it with `edit_workspace`. A skipped meal is out of the range: the
  optimizer does not fill it, the Purchase and the consumed cost leave it out,
  the Proposal shows it as skipped and confirming saves nothing for it.
  `unskip` puts it back.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.PlanningAgent.{FakeOptimizer, HouseholdContext, ProposalValidator}
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
    # 100 g of pasta per batch; 1 kg costs 1_000 cents.
    recipe = recipe!("Fictitious pasta bake", [pasta], quantities: %{pasta.id => {100_000, :g}})
    product!(pasta, name: "Fictitious penne 1 kg", package: {1_000_000, :g}, price_cents: 1_000)

    %{household: household, recipe: recipe}
  end

  defp start!(household, script) do
    attrs = session_attrs(household, household.owner, {@monday, @tuesday}, ["lunch", "dinner"])

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, [notify: self()]},
        clock: fn -> @now end,
        subscriber: self()
      )

    {session_id, pid}
  end

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

  defp plan(edits) do
    Enum.map(edits, &{:tool_calls, [{"edit_workspace", &1}]}) ++
      [
        {:tool_calls, [{"run_optimizer", %{}}]},
        {:tool_calls, [{"present_proposal", %{}}]}
      ]
  end

  defp proposal!(session_id) do
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}
    proposal
  end

  defp keys(proposal), do: Enum.map(proposal["meals"], &{&1["date"], &1["slot"]})

  @skip %{"action" => "skip", "date" => "2026-11-03", "slot" => "dinner"}
  @unskip %{"action" => "unskip", "date" => "2026-11-03", "slot" => "dinner"}

  test "a skipped meal is not planned, bought, costed or saved", %{household: h} do
    {session_id, pid} = start!(h, plan([@skip]) ++ [{:text, "Planned."}])

    [skipped, _run, presented] = turn!(session_id, pid, "Tuesday night we eat out")

    assert skipped["status"] == "ok"
    assert skipped["skipped"] == %{"date" => "2026-11-03", "slot" => "dinner"}

    assert_receive {:optimizer_payload, payload}
    assert payload["skipped_meals"] == [%{"day" => "2026-11-03", "slot" => "dinner"}]

    proposal = proposal!(session_id)

    assert keys(proposal) == [
             {"2026-11-02", "lunch"},
             {"2026-11-02", "dinner"},
             {"2026-11-03", "lunch"}
           ]

    assert proposal["skipped"] == [%{"date" => "2026-11-03", "slot" => "dinner"}]
    assert presented["skipped"] == proposal["skipped"]

    # Three batches of 100 g, not four.
    assert [%{"quantity_milli" => 300_000}] = proposal["purchase"]["lines"]
    assert proposal["consumed_cost"]["total_cents"] == 300

    assert {:ok, _summary} =
             Session.confirm(h.account_id, h.owner.membership_id, proposal["proposal_id"])

    stored =
      Repo.all(
        from(m in ScheduledMeal,
          where: m.account_id == ^h.account_id,
          select: {m.date, m.slot}
        )
      )

    assert length(stored) == 3
    refute {@tuesday, :dinner} in stored
  end

  test "unskip puts the meal back in the plan", %{household: h} do
    script = plan([@skip]) ++ [{:text, "Planned."}] ++ plan([@unskip]) ++ [{:text, "Back."}]
    {session_id, pid} = start!(h, script)

    _ = turn!(session_id, pid, "Tuesday night we eat out")
    first = proposal!(session_id)
    assert length(first["meals"]) == 3

    [unskipped, _run, _presented] =
      session_id |> turn!(pid, "We eat at home after all") |> Enum.take(-3)

    assert unskipped["status"] == "ok"
    assert unskipped["unskipped"] == %{"date" => "2026-11-03", "slot" => "dinner"}

    second = proposal!(session_id)
    assert length(second["meals"]) == 4
    assert second["skipped"] == []
  end

  test "a skip discards the draft and is shown by get_workspace", %{household: h} do
    script = [
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"edit_workspace", @skip}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:tool_calls, [{"get_workspace", %{}}]},
      {:text, "done"}
    ]

    {session_id, pid} = start!(h, script)
    [_run, _skip, presented, workspace] = turn!(session_id, pid, "Plan")

    assert presented["error"] == "no_plan_to_present"
    assert workspace["skipped"] == [%{"date" => "2026-11-03", "slot" => "dinner"}]
  end

  test "skipping removes a Pin at that meal", %{household: h, recipe: recipe} do
    pin = %{
      "action" => "pin",
      "date" => "2026-11-03",
      "slot" => "dinner",
      "recipe_id" => recipe.id
    }

    {session_id, pid} = start!(h, plan([pin, @skip]) ++ [{:text, "Planned."}])

    [_pin, skipped, run, _presented] = turn!(session_id, pid, "Pin then skip")

    assert skipped["unpinned"] == true
    refute Enum.any?(run["meals"], &(&1["date"] == "2026-11-03" and &1["slot"] == "dinner"))
  end

  test "a skip outside the range is refused", %{household: h} do
    outside = %{"action" => "skip", "date" => "2026-12-01", "slot" => "dinner"}
    {session_id, pid} = start!(h, [{:tool_calls, [{"edit_workspace", outside}]}, {:text, "no"}])

    [refused] = turn!(session_id, pid, "Skip")
    assert refused["error"] == "date_outside_range"
  end

  test "the validator needs no meal at a skipped meal and refuses one there",
       %{household: h, recipe: recipe} do
    ctx = %{
      account_id: h.account_id,
      range: {@monday, @monday},
      slots: ["lunch", "dinner"],
      household: HouseholdContext.load(h.account_id, h.owner.user_id),
      skipped: MapSet.new([{@monday, "dinner"}])
    }

    lunch = %{date: @monday, slot: "lunch", recipe_id: recipe.id}
    dinner = %{date: @monday, slot: "dinner", recipe_id: recipe.id}

    assert {:valid, [_lunch]} = ProposalValidator.validate([lunch], ctx)

    assert {:invalid, [%{"type" => "skipped_meal", "slot" => "dinner"}]} =
             ProposalValidator.validate([lunch, dinner], ctx)
  end
end
