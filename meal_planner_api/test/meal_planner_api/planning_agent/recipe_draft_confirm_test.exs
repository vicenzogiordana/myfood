defmodule MealPlannerApi.PlanningAgent.RecipeDraftConfirmTest do
  @moduledoc """
  Recipe Drafts in Proposals through the session module (issue #104, spec
  #93 user stories 37, 40 and 41): an AI-created Draft can be planned and is
  disclosed as AI-created; confirming a Proposal that uses it saves it as a
  private AI-created Household Recipe; a Planning Session that ends
  unconfirmed leaves nothing behind.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Catalog.{Recipe, RecipeIngredient, RecipeStep}
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Persistence.Shopping.ShoppingItem
  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @draft_name "Fictitious drafted sausage risotto"

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    squash = ingredient!("Fictitious sausage", [:contains_meat])
    rice = ingredient!("Fictitious risotto rice")
    product!(squash, package: {1_000_000, :g}, price_cents: 900)
    product!(rice, package: {1_000_000, :g}, price_cents: 1_500)

    # A traditional recipe keeps search results non-empty for every slot.
    recipe!("Fictitious plain rice", [rice])

    %{household: household, squash: squash, rice: rice}
  end

  defp draft_args(ctx) do
    %{
      "name" => @draft_name,
      "servings" => 2,
      "slots" => ["lunch", "dinner"],
      "origin" => "ai_created",
      "ingredients" => [
        %{"ingredient" => ctx.squash.name, "quantity" => 250, "unit" => "g"},
        %{"ingredient" => ctx.rice.name, "quantity" => 150, "unit" => "g"}
      ],
      "steps" => ["Toast the rice.", "Add the sausage and stir."]
    }
  end

  # The optimizer picks the candidate labelled `name` for every day and slot.
  defp pick(name) do
    fn payload ->
      meals =
        for day <- payload["days"], slot <- payload["slots"] do
          %{"recipe_id" => id} =
            Enum.find(payload["candidates_by_slot"][slot], &(&1["label"] == name))

          %{"day" => day, "slot" => slot, "recipe_id" => id}
        end

      {:ok, %{"meals" => meals}}
    end
  end

  defp present_draft!(household, ctx) do
    script = [
      {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:text, "Here is a plan with a new AI-created recipe."}
    ]

    attrs = session_attrs(household, household.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script},
        optimizer: {FakeOptimizer, result: pick(@draft_name)},
        subscriber: self()
      )

    :ok = Session.send_message(pid, "Plan Monday with something new")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "recipe_draft", "recipe_id" => draft_id}}

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}

    %{session_id: session_id, pid: pid, proposal: proposal, draft_id: draft_id}
  end

  test "a Proposal discloses an AI-created Draft it uses", %{household: h} = ctx do
    %{proposal: proposal, draft_id: draft_id} = present_draft!(h, ctx)

    assert proposal["status"] == "valid"

    for meal <- proposal["meals"] do
      assert meal["recipe_id"] == draft_id
      assert meal["name"] == @draft_name
      assert meal["origin"] == "ai_created"
      assert meal["draft"] == true
    end

    # The Purchase is computed from the Draft's ingredients: 500 g of squash
    # and 300 g of rice, one 1 kg package each.
    assert proposal["purchase"]["total_cents"] == 900 + 1_500
    assert proposal["purchase"]["complete"] == true
  end

  # Staples are assumed at home (issue #162): never in the Purchase.
  test "a Draft's staples are not in the Purchase", %{household: h} = ctx do
    args =
      Map.update!(
        draft_args(ctx),
        "ingredients",
        &(&1 ++
            [
              %{"ingredient" => "Water", "quantity" => 400, "unit" => "ml"},
              %{"ingredient" => "Salt", "quantity" => 4, "unit" => "g"}
            ])
      )

    script = [
      {:tool_calls, [{"create_recipe", args}]},
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:text, "Here is the plan."}
    ]

    attrs = session_attrs(h, h.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script},
        optimizer: {FakeOptimizer, result: pick(@draft_name)},
        subscriber: self()
      )

    :ok = Session.send_message(pid, "Plan Monday with something new")

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}
    assert proposal["purchase"]["total_cents"] == 900 + 1_500
    assert proposal["purchase"]["complete"] == true
    assert proposal["purchase"]["missing_prices"] == []
  end

  test "confirmation saves the used Draft as a private AI-created Household Recipe",
       %{household: h} = ctx do
    %{proposal: proposal, draft_id: draft_id} = present_draft!(h, ctx)

    assert {:ok, summary} =
             Session.confirm(h.account_id, h.owner.membership_id, proposal["proposal_id"])

    assert summary.meals_count == 2

    recipe = Repo.get!(Recipe, draft_id)
    assert recipe.name == @draft_name
    assert recipe.source == :ai_generated
    assert recipe.account_id == h.account_id
    assert recipe.created_by_user_id == h.owner.user_id
    assert recipe.servings == 2
    assert recipe.suitable_for_slots == ["lunch", "dinner"]

    assert Repo.aggregate(from(ri in RecipeIngredient, where: ri.recipe_id == ^draft_id), :count) ==
             2

    assert from(s in RecipeStep, where: s.recipe_id == ^draft_id, order_by: s.step_number)
           |> Repo.all()
           |> Enum.map(& &1.instructions) == ["Toast the rice.", "Add the sausage and stir."]

    assert from(m in ScheduledMeal, where: m.account_id == ^h.account_id, select: m.recipe_id)
           |> Repo.all() == [draft_id, draft_id]

    assert Repo.aggregate(from(i in ShoppingItem, where: i.account_id == ^h.account_id), :count) ==
             2
  end

  test "a Draft breaking a Restriction added after it was shown cannot be confirmed",
       %{household: h} = ctx do
    %{proposal: proposal, draft_id: draft_id} = present_draft!(h, ctx)
    diet!(h.owner, :vegetarian)

    assert {:error, :revalidation_conflict} =
             Session.confirm(h.account_id, h.owner.membership_id, proposal["proposal_id"])

    refute Repo.get(Recipe, draft_id)
    assert Repo.all(from(m in ScheduledMeal, where: m.account_id == ^h.account_id)) == []
  end

  test "Drafts disappear when the Planning Session ends unconfirmed", %{household: h} = ctx do
    %{pid: pid, draft_id: draft_id} = present_draft!(h, ctx)
    ref = Process.monitor(pid)

    :ok = Session.cancel(pid, %{membership_id: h.owner.membership_id, owner?: true})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    refute Repo.get(Recipe, draft_id)
    refute Repo.get_by(Recipe, name: @draft_name)

    # A new Planning Session of the Household does not see the old Draft.
    script = [{:tool_calls, [{"get_recipe", %{"recipe_id" => draft_id}}]}, {:text, "done"}]
    attrs = session_attrs(h, h.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs, model: {Scripted, script: script, notify: self()}, subscriber: self())

    :ok = Session.send_message(pid, "Show the risotto")
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
    assert_receive {:scripted_model_request, _first}
    assert_receive {:scripted_model_request, %{messages: messages}}
    assert %{role: :tool_result, content: %{"error" => "recipe_not_found"}} = List.last(messages)
  end

  # Issue #151: a revised Draft changes what the shown Proposal costs, so the
  # Proposal that used it is voided and can no longer be confirmed.
  test "revising a Draft the shown Proposal uses voids that Proposal", %{household: h} = ctx do
    revised =
      put_in(draft_args(ctx), ["ingredients", Access.at(0), "quantity"], 600)

    script = [
      {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:text, "Here is a plan with a new AI-created recipe."},
      {:tool_calls, [{"create_recipe", revised}]},
      {:text, "I added more sausage."}
    ]

    attrs = session_attrs(h, h.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, result: pick(@draft_name)},
        subscriber: self()
      )

    :ok = Session.send_message(pid, "Plan Monday with something new")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "proposal", "proposal_id" => proposal_id}}

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

    :ok = Session.send_message(pid, "More sausage, please")

    assert_receive {:planning_agent_event, ^session_id,
                    %{
                      "type" => "proposal_invalidated",
                      "proposal_id" => ^proposal_id,
                      "reason" => "recipe_draft_revised"
                    }}

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

    # The revision's tool result tells the agent the Proposal is void.
    assert %{"status" => "revised", "proposal_voided" => true} = last_tool_result()

    assert {:error, :stale_proposal} =
             Session.confirm(h.account_id, h.owner.membership_id, proposal_id)

    assert Repo.all(from(m in ScheduledMeal, where: m.account_id == ^h.account_id)) == []
    refute Repo.get_by(Recipe, name: @draft_name)
    assert Session.current_proposal(pid) == nil
  end

  test "revising a Draft the shown Proposal does not use keeps that Proposal",
       %{household: h} = ctx do
    other = %{draft_args(ctx) | "name" => "Fictitious unused risotto"}

    script = [
      {:tool_calls, [{"create_recipe", draft_args(ctx)}, {"create_recipe", other}]},
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:text, "Here is the plan."},
      {:tool_calls,
       [{"create_recipe", put_in(other, ["ingredients", Access.at(0), "quantity"], 600)}]},
      {:text, "Revised the other recipe."}
    ]

    attrs = session_attrs(h, h.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, result: pick(@draft_name)},
        subscriber: self()
      )

    :ok = Session.send_message(pid, "Plan Monday with something new")

    assert_receive {:planning_agent_event, ^session_id,
                    %{"type" => "proposal", "proposal_id" => proposal_id}}

    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
    :ok = Session.send_message(pid, "Change the other one")
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

    refute_received {:planning_agent_event, ^session_id, %{"type" => "proposal_invalidated"}}

    assert {:ok, %{meals_count: 2}} =
             Session.confirm(h.account_id, h.owner.membership_id, proposal_id)
  end

  defp last_tool_result do
    requests =
      Stream.repeatedly(fn ->
        receive do
          {:scripted_model_request, request} -> request
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    %{messages: messages} = List.last(requests)
    %{role: :tool_result, content: content} = List.last(messages)
    content
  end

  describe "pinning a Draft (issue #154)" do
    # Pins the Draft the previous tool result created to Monday's dinner.
    defp pin_created_draft(slot) do
      fn %{messages: messages} ->
        %{role: :tool_result, content: %{"recipe_id" => id}} = List.last(messages)

        {:tool_calls,
         [
           {"edit_workspace",
            %{
              "action" => "pin",
              "date" => Date.to_iso8601(@monday),
              "slot" => slot,
              "recipe_id" => id
            }}
         ]}
      end
    end

    defp run_pin_script(household, script) do
      attrs = session_attrs(household, household.owner, {@monday, @monday})

      {:ok, %{session_id: session_id, pid: pid}} =
        Session.start(attrs,
          model: {Scripted, script: script, notify: self()},
          optimizer: {FakeOptimizer, []},
          subscriber: self()
        )

      :ok = Session.send_message(pid, "Plan Monday with the new recipe for dinner")
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}
      session_id
    end

    defp tool_results do
      receive do
        {:scripted_model_request, %{messages: messages}} ->
          later = tool_results()
          if later == [], do: for(%{role: :tool_result} = m <- messages, do: m), else: later
      after
        0 -> []
      end
    end

    test "create_recipe -> pin the Draft -> run_optimizer -> present_proposal succeeds",
         %{household: h} = ctx do
      script = [
        {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
        pin_created_draft("dinner"),
        {:tool_calls, [{"run_optimizer", %{}}]},
        {:tool_calls, [{"present_proposal", %{}}]},
        {:text, "Here is the plan."}
      ]

      session_id = run_pin_script(h, script)

      assert_received {:planning_agent_event, ^session_id,
                       %{"type" => "recipe_draft", "recipe_id" => draft_id}}

      assert_received {:planning_agent_event, ^session_id,
                       %{"type" => "proposal", "status" => "valid"} = proposal}

      dinner = Enum.find(proposal["meals"], &(&1["slot"] == "dinner"))
      assert dinner["recipe_id"] == draft_id
      assert dinner["draft"] == true

      [_created, %{content: pinned} | _] = tool_results()
      assert pinned["status"] == "ok"
      assert pinned["pinned"]["recipe_id"] == draft_id
      assert pinned["pinned"]["name"] == @draft_name
    end

    test "a Draft cannot be pinned to a slot it is not for", %{household: h} = ctx do
      args = Map.put(draft_args(ctx), "slots", ["lunch"])

      script = [
        {:tool_calls, [{"create_recipe", args}]},
        pin_created_draft("dinner"),
        {:text, "done"}
      ]

      _session_id = run_pin_script(h, script)
      [_created, %{content: refused}] = tool_results()
      assert refused["error"] == "recipe_not_for_slot"
    end

    test "a dictated Draft cannot be pinned until the Member saves it", %{household: h} = ctx do
      args = Map.put(draft_args(ctx), "origin", "user_created")

      script = [
        {:tool_calls, [{"create_recipe", args}]},
        pin_created_draft("dinner"),
        {:text, "done"}
      ]

      _session_id = run_pin_script(h, script)
      [_created, %{content: refused}] = tool_results()
      assert refused["error"] == "recipe_not_plannable"
    end

    test "a Draft breaking a guest's Restriction cannot be pinned to that meal",
         %{household: h} = ctx do
      guests = %{
        "action" => "set_guests",
        "date" => Date.to_iso8601(@monday),
        "slot" => "dinner",
        "guests" => 2,
        "guest_restrictions" => ["vegetarian"]
      }

      script = [
        {:tool_calls, [{"edit_workspace", guests}]},
        {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
        pin_created_draft("dinner"),
        {:text, "done"}
      ]

      _session_id = run_pin_script(h, script)
      [_guests, _created, %{content: refused}] = tool_results()
      assert refused["error"] == "restriction_conflict"
    end
  end

  describe "a pinned Draft stays on its meals (issue #162)" do
    @tuesday ~D[2026-11-03]

    # The optimizer prefers the Draft wherever the payload lets it: as if it
    # were the cheapest candidate. A fixed meal keeps its recipe and an
    # avoided meal never takes it.
    defp prefer(name) do
      fn payload ->
        fixed = Map.new(payload["fixed_meals"], &{{&1["day"], &1["slot"]}, &1["recipe_id"]})
        avoided = MapSet.new(payload["avoided_meals"], &{&1["day"], &1["slot"], &1["recipe_id"]})

        meals =
          for day <- payload["days"], slot <- payload["slots"] do
            candidates = payload["candidates_by_slot"][slot]
            preferred = Enum.find(candidates, &(&1["label"] == name))

            recipe_id =
              cond do
                Map.has_key?(fixed, {day, slot}) ->
                  Map.fetch!(fixed, {day, slot})

                preferred && not MapSet.member?(avoided, {day, slot, preferred["recipe_id"]}) ->
                  preferred["recipe_id"]

                true ->
                  candidates
                  |> Enum.reject(&MapSet.member?(avoided, {day, slot, &1["recipe_id"]}))
                  |> hd()
                  |> Map.fetch!("recipe_id")
              end

            %{"day" => day, "slot" => slot, "recipe_id" => recipe_id}
          end

        {:ok, %{"meals" => meals}}
      end
    end

    defp pin_draft(date, slot) do
      fn %{messages: messages} ->
        id =
          Enum.find_value(Enum.reverse(messages), fn
            %{role: :tool_result, content: %{"recipe_id" => id, "draft" => true}} -> id
            _ -> nil
          end)

        {:tool_calls,
         [
           {"edit_workspace",
            %{
              "action" => "pin",
              "date" => Date.to_iso8601(date),
              "slot" => slot,
              "recipe_id" => id
            }}
         ]}
      end
    end

    defp repeat_draft do
      fn %{messages: messages} ->
        id =
          Enum.find_value(Enum.reverse(messages), fn
            %{role: :tool_result, content: %{"recipe_id" => id, "draft" => true}} -> id
            _ -> nil
          end)

        {:tool_calls, [{"edit_workspace", %{"action" => "repeat_recipe", "recipe_id" => id}}]}
      end
    end

    defp plan_two_days!(household, steps) do
      script =
        steps ++
          [
            {:tool_calls, [{"run_optimizer", %{}}]},
            {:tool_calls, [{"present_proposal", %{}}]},
            {:text, "Here is the plan."}
          ]

      attrs = session_attrs(household, household.owner, {@monday, @tuesday})

      {:ok, %{session_id: session_id, pid: pid}} =
        Session.start(attrs,
          model: {Scripted, script: script, notify: self()},
          optimizer: {FakeOptimizer, result: prefer(@draft_name), notify: self()},
          subscriber: self()
        )

      :ok = Session.send_message(pid, "Burgers on Monday dinner")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "recipe_draft", "recipe_id" => draft_id}}

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "proposal"} = proposal}
      assert_receive {:optimizer_payload, payload}
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}

      %{draft_id: draft_id, proposal: proposal, payload: payload}
    end

    defp draft_meals(proposal, draft_id) do
      for %{"recipe_id" => ^draft_id} = meal <- proposal["meals"],
          do: {meal["date"], meal["slot"]}
    end

    test "is not chosen for other meals, even as the preferred candidate",
         %{household: h} = ctx do
      %{draft_id: draft_id, proposal: proposal, payload: payload} =
        plan_two_days!(h, [
          {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
          pin_draft(@monday, "dinner")
        ])

      assert proposal["status"] == "valid"
      assert draft_meals(proposal, draft_id) == [{"2026-11-02", "dinner"}]

      # Its own slot holds it only for the pinned meal: every other meal of
      # that slot avoids it, and the other slot never offers it.
      refute draft_id in Enum.map(payload["candidates_by_slot"]["lunch"], & &1["recipe_id"])

      assert %{"day" => "2026-11-03", "slot" => "dinner", "recipe_id" => draft_id} in payload[
               "avoided_meals"
             ]
    end

    test "after the household asks, it can be planned on other meals", %{household: h} = ctx do
      %{draft_id: draft_id, proposal: proposal} =
        plan_two_days!(h, [
          {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
          pin_draft(@monday, "dinner"),
          repeat_draft()
        ])

      assert proposal["status"] == "valid"
      assert length(draft_meals(proposal, draft_id)) == 4
    end

    test "pinning it to another meal adds only that meal", %{household: h} = ctx do
      %{draft_id: draft_id, proposal: proposal} =
        plan_two_days!(h, [
          {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
          pin_draft(@monday, "dinner"),
          pin_draft(@tuesday, "lunch")
        ])

      assert Enum.sort(draft_meals(proposal, draft_id)) == [
               {"2026-11-02", "dinner"},
               {"2026-11-03", "lunch"}
             ]
    end

    test "a revision keeps it on its meals", %{household: h} = ctx do
      revise = fn %{messages: messages} ->
        id =
          Enum.find_value(Enum.reverse(messages), fn
            %{role: :tool_result, content: %{"recipe_id" => id, "draft" => true}} -> id
            _ -> nil
          end)

        args = Map.merge(draft_args(ctx), %{"replaces_recipe_id" => id, "servings" => 3})
        {:tool_calls, [{"create_recipe", args}]}
      end

      %{draft_id: draft_id, proposal: proposal} =
        plan_two_days!(h, [
          {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
          pin_draft(@monday, "dinner"),
          revise
        ])

      assert draft_meals(proposal, draft_id) == [{"2026-11-02", "dinner"}]
    end

    test "an unpinned Draft is still a candidate everywhere", %{household: h} = ctx do
      %{draft_id: draft_id, proposal: proposal} =
        plan_two_days!(h, [{:tool_calls, [{"create_recipe", draft_args(ctx)}]}])

      assert length(draft_meals(proposal, draft_id)) == 4
    end

    test "only a Draft of this chat can be repeated", %{household: h} = ctx do
      script = [
        {:tool_calls,
         [
           {"edit_workspace", %{"action" => "repeat_recipe", "recipe_id" => Ecto.UUID.generate()}}
         ]},
        {:text, "done"}
      ]

      attrs = session_attrs(h, h.owner, {@monday, @monday})

      {:ok, %{session_id: session_id, pid: pid}} =
        Session.start(attrs,
          model: {Scripted, script: script, notify: self()},
          optimizer: {FakeOptimizer, []},
          subscriber: self()
        )

      :ok = Session.send_message(pid, "Repeat it")
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
      assert_receive {:scripted_model_request, _first}
      assert_receive {:scripted_model_request, %{messages: messages}}
      assert %{role: :tool_result, content: %{"error" => "not_a_draft"}} = List.last(messages)
      _ = ctx
    end
  end
end
