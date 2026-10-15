defmodule MealPlannerApi.PlanningAgent.RecipeSaveTest do
  @moduledoc """
  Dictated recipes through the session module (issue #104, spec #93 user
  stories 42 and 43): the agent builds a dictated recipe with the same rules
  as any Draft, and it becomes a user-created Household Recipe only through
  the Member's explicit save action.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Catalog.Recipe
  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @dictated "Fictitious grandma dumplings"

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)
    flour = ingredient!("Fictitious dumpling flour", [:contains_gluten])
    recipe!("Fictitious plain soup", [flour])

    %{household: household, flour: flour}
  end

  defp args(ctx, origin, name \\ @dictated) do
    %{
      "name" => name,
      "servings" => 4,
      "slots" => ["dinner"],
      "origin" => origin,
      "ingredients" => [%{"ingredient" => ctx.flour.name, "quantity" => 500, "unit" => "g"}],
      "steps" => ["Knead.", "Boil."]
    }
  end

  # Starts a session whose first turn drafts the given recipes, and returns
  # the Draft ids in order.
  defp draft!(household, drafts, extra_script \\ []) do
    script =
      Enum.map(drafts, &{:tool_calls, [{"create_recipe", &1}]}) ++
        extra_script ++ [{:text, "Drafted."}]

    attrs = session_attrs(household, household.owner, {@monday, @monday}, ["dinner"])

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script},
        optimizer: {FakeOptimizer, notify: self()},
        subscriber: self()
      )

    :ok = Session.send_message(pid, "My grandma's dumplings: ...")

    ids =
      for _ <- drafts do
        assert_receive {:planning_agent_event, ^session_id,
                        %{"type" => "recipe_draft", "recipe_id" => id}}

        id
      end

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}
    %{session_id: session_id, pid: pid, ids: ids}
  end

  test "a dictated recipe is saved as a user-created Household Recipe on save",
       %{household: h} = ctx do
    %{session_id: session_id, pid: pid, ids: [id]} = draft!(h, [args(ctx, "user_created")])

    # Built, shown, but not saved until the Member presses save.
    refute Repo.get(Recipe, id)

    assert {:ok, %{recipe_id: ^id, origin: "user_created"}} =
             Session.save_recipe(pid, h.owner.membership_id, id)

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "recipe_saved", "recipe_id" => ^id, "origin" => "user_created"}}

    recipe = Repo.get!(Recipe, id)
    assert recipe.source == :user_created
    assert recipe.account_id == h.account_id
    assert recipe.name == @dictated
    assert recipe.servings == 4

    # Saved once: the Draft left the Workspace.
    assert {:error, :not_found} = Session.save_recipe(pid, h.owner.membership_id, id)
  end

  test "a dictated recipe is never saved without the save action", %{household: h} = ctx do
    %{pid: pid, ids: [id]} = draft!(h, [args(ctx, "user_created")])
    ref = Process.monitor(pid)

    :ok = Session.cancel(pid, %{membership_id: h.owner.membership_id, owner?: true})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    refute Repo.get(Recipe, id)
    refute Repo.get_by(Recipe, name: @dictated)
  end

  test "an unsaved dictated recipe is not planned", %{household: h} = ctx do
    %{ids: [_id]} =
      draft!(h, [args(ctx, "user_created")], [{:tool_calls, [{"run_optimizer", %{}}]}])

    assert_receive {:optimizer_payload, payload}, 1_000
    labels = Enum.map(payload["candidates_by_slot"]["dinner"], & &1["label"])
    assert "Fictitious plain soup" in labels
    refute @dictated in labels
  end

  test "only the session's Member saves, and only dictated recipes", %{household: h} = ctx do
    other = member!(h)

    %{pid: pid, ids: [dictated, ai]} =
      draft!(h, [args(ctx, "user_created"), args(ctx, "ai_created", "Fictitious AI dumplings")])

    assert {:error, :forbidden} = Session.save_recipe(pid, other.membership_id, dictated)
    assert {:error, :not_dictated} = Session.save_recipe(pid, h.owner.membership_id, ai)
    assert {:error, :not_found} = Session.save_recipe(pid, h.owner.membership_id, "nope")

    refute Repo.get(Recipe, dictated)
    refute Repo.get(Recipe, ai)
  end
end
