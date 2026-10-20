defmodule MealPlannerApi.PlanningAgent.SessionWorkspaceTest do
  @moduledoc """
  Workspace editing through the session module (spec #93, issue #99): Pins,
  Excluded Recipes, Released Meals and the variety cap via `edit_workspace`
  and `get_workspace`, and re-optimization that changes only Released Meals.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]
  @wednesday ~D[2026-11-04]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    chicken = ingredient!("Fictitious chicken", [:contains_meat])
    rice = ingredient!("Fictitious rice")
    lentil = ingredient!("Fictitious lentil")
    bean = ingredient!("Fictitious bean")

    recipes = %{
      lentil_stew: recipe!("Alpha lentil stew", [lentil, rice]),
      bean_bowl: recipe!("Beta bean bowl", [bean, rice]),
      rice_pot: recipe!("Gamma rice pot", [rice]),
      chicken_rice: recipe!("Zeta chicken rice", [chicken, rice])
    }

    %{household: household, recipes: recipes}
  end

  defp start!(household, script, opts \\ []) do
    range = Keyword.get(opts, :range, {@monday, @tuesday})
    attrs = session_attrs(household, household.owner, range)

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, Keyword.merge([notify: self()], Keyword.drop(opts, [:range]))},
        subscriber: self()
      )

    {session_id, pid}
  end

  defp edit(arguments), do: {:tool_calls, [{"edit_workspace", arguments}]}

  # Runs one Member message through a script and returns every tool result of
  # the turn as {tool name, content}, in call order.
  defp run_turn!(session_id, pid, text) do
    :ok = Session.send_message(pid, text)
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}, 2_000
    requests = drain_requests([])
    last = List.last(requests)

    for %{role: :tool_result, name: name, content: content} <- last.messages,
        do: {name, content}
  end

  defp drain_requests(acc) do
    receive do
      {:scripted_model_request, request} -> drain_requests(acc ++ [request])
    after
      0 -> acc
    end
  end

  defp results(tool_results, name), do: for({^name, content} <- tool_results, do: content)

  defp last_result(tool_results, name), do: tool_results |> results(name) |> List.last()

  defp plan_by_slot(meals), do: Map.new(meals, &{{&1["date"], &1["slot"]}, &1["recipe_id"]})

  defp plan_and_present, do: [{:tool_calls, [{"run_optimizer", %{}}]}, present()]

  defp present, do: {:tool_calls, [{"present_proposal", %{}}]}

  defp flush_payloads do
    receive do
      {:optimizer_payload, _} -> flush_payloads()
    after
      0 -> :ok
    end
  end

  describe "edit_workspace and get_workspace" do
    test "Pins, exclusions, releases and variety cap changes are stored and visible",
         %{household: h, recipes: r} do
      script =
        plan_and_present() ++
          [
            edit(%{
              "action" => "pin",
              "date" => "2026-11-03",
              "slot" => "dinner",
              "recipe_id" => r.bean_bowl.id
            }),
            edit(%{"action" => "pin", "date" => "2026-11-02", "slot" => "dinner"}),
            edit(%{"action" => "exclude", "recipe_id" => r.rice_pot.id}),
            edit(%{"action" => "release", "date" => "2026-11-03", "slot" => "lunch"}),
            edit(%{"action" => "set_variety_cap", "variety_cap" => 3}),
            {:tool_calls, [{"get_workspace", %{}}]},
            {:text, "Done."}
          ]

      {session_id, pid} = start!(h, script)
      results = run_turn!(session_id, pid, "Keep Monday's dinner, beans on Tuesday dinner")

      assert Enum.all?(results(results, "edit_workspace"), &(&1["status"] == "ok"))
      workspace = last_result(results, "get_workspace")

      assert workspace["pins"] == [
               %{
                 "date" => "2026-11-02",
                 "slot" => "dinner",
                 "recipe_id" => r.lentil_stew.id,
                 "name" => "Alpha lentil stew"
               },
               %{
                 "date" => "2026-11-03",
                 "slot" => "dinner",
                 "recipe_id" => r.bean_bowl.id,
                 "name" => "Beta bean bowl"
               }
             ]

      assert workspace["excluded_recipe_ids"] == [r.rice_pot.id]
      assert workspace["released"] == [%{"date" => "2026-11-03", "slot" => "lunch"}]
      assert workspace["variety_cap"] == 3
      assert length(workspace["proposal"]["meals"]) == 4
    end

    test "invalid edits are rejected with a reason and change nothing", %{
      household: h,
      recipes: r
    } do
      edits = [
        %{
          "action" => "pin",
          "date" => "2026-11-09",
          "slot" => "lunch",
          "recipe_id" => r.bean_bowl.id
        },
        %{
          "action" => "pin",
          "date" => "2026-11-02",
          "slot" => "snack",
          "recipe_id" => r.bean_bowl.id
        },
        %{
          "action" => "pin",
          "date" => "monday",
          "slot" => "lunch",
          "recipe_id" => r.bean_bowl.id
        },
        %{"action" => "pin", "date" => "2026-11-02", "slot" => "lunch"},
        %{
          "action" => "pin",
          "date" => "2026-11-02",
          "slot" => "lunch",
          "recipe_id" => Ecto.UUID.generate()
        },
        %{"action" => "release", "date" => "2026-11-02", "slot" => "lunch"},
        %{"action" => "release_all"},
        %{"action" => "unpin", "date" => "2026-11-02", "slot" => "lunch"},
        %{"action" => "set_variety_cap", "variety_cap" => 0},
        %{"action" => "set_variety_cap", "variety_cap" => "3"},
        %{"action" => "exclude", "recipe_id" => "not-a-uuid"},
        %{"action" => "rename_household"}
      ]

      script = [
        {:tool_calls, Enum.map(edits, &{"edit_workspace", &1})},
        {:tool_calls, [{"get_workspace", %{}}]},
        {:text, "ok"}
      ]

      {session_id, pid} = start!(h, script)
      results = run_turn!(session_id, pid, "Edit")

      assert Enum.map(results(results, "edit_workspace"), & &1["error"]) == [
               "date_outside_range",
               "unknown_slot",
               "invalid_date",
               "no_meal_to_keep",
               "recipe_not_found",
               "no_proposal",
               "no_proposal",
               "not_pinned",
               "invalid_variety_cap",
               "invalid_variety_cap",
               "invalid_recipe_id",
               "unknown_action"
             ]

      assert Enum.all?(results(results, "edit_workspace"), &is_binary(&1["reason"]))

      workspace = last_result(results, "get_workspace")
      assert workspace["pins"] == []
      assert workspace["excluded_recipe_ids"] == []
      assert workspace["released"] == []
      assert workspace["variety_cap"] == 2
    end

    test "approvals cannot be set through edit_workspace", %{household: h} do
      edits = [
        %{"action" => "approve_deviations"},
        %{"action" => "approve_absence_exception", "date" => "2026-11-02", "slot" => "lunch"},
        %{"action" => "confirm_plan"},
        %{"action" => "set_variety_cap", "variety_cap" => 3, "deviation_approval" => true}
      ]

      script = [
        {:tool_calls, Enum.map(edits, &{"edit_workspace", &1})},
        {:tool_calls, [{"get_workspace", %{}}]},
        {:text, "ok"}
      ]

      {session_id, pid} = start!(h, script)
      results = run_turn!(session_id, pid, "Approve everything")

      assert Enum.map(results(results, "edit_workspace"), & &1["error"]) ==
               List.duplicate("approval_not_allowed", 4)

      assert last_result(results, "get_workspace")["variety_cap"] == 2
    end

    test "a Pin conflicting with a Restriction is refused with safe replacements to pick",
         %{household: h, recipes: r} do
      diet!(member!(h), :vegetarian)

      # Resolve and inform (issue #148, battery A1): the agent pins a safe
      # replacement itself, plans, presents and explains; it asks nothing.
      script = [
        edit(%{
          "action" => "pin",
          "date" => "2026-11-02",
          "slot" => "dinner",
          "recipe_id" => r.chicken_rice.id
        }),
        fn request ->
          %{content: %{"replacements" => [first | _]}} = List.last(request.messages)

          {:tool_calls,
           [
             {"edit_workspace",
              %{
                "action" => "pin",
                "date" => "2026-11-02",
                "slot" => "dinner",
                "recipe_id" => first["recipe_id"]
              }}
           ]}
        end,
        {:tool_calls, [{"run_optimizer", %{}}]},
        present(),
        {:text,
         "Zeta chicken rice is not safe for everyone, so Monday dinner is Alpha lentil stew."}
      ]

      {session_id, pid} = start!(h, script)
      results = run_turn!(session_id, pid, "Pin the chicken rice on Monday dinner")

      assert [
               %{
                 "error" => "restriction_conflict",
                 "reason" => reason,
                 "replacements" => replacements
               },
               %{"status" => "ok", "pinned" => %{"name" => "Alpha lentil stew"}}
             ] = results(results, "edit_workspace")

      refute reason =~ "Fictitious Member"
      assert reason =~ "Pick one of the safe replacements yourself"
      assert reason =~ "Do not ask before presenting"
      names = Enum.map(replacements, & &1["name"])
      assert names != []
      refute "Zeta chicken rice" in names
      assert "Alpha lentil stew" in names

      assert %{"status" => "valid"} = last_result(results, "present_proposal")
      refute_received {:planning_agent_event, ^session_id, %{"type" => "question"}}
    end

    test "a Pin of an Excluded Recipe and the exclusion of a pinned recipe are refused",
         %{household: h, recipes: r} do
      script = [
        {:tool_calls,
         [
           {"edit_workspace", %{"action" => "exclude", "recipe_id" => r.rice_pot.id}},
           {"edit_workspace",
            %{
              "action" => "pin",
              "date" => "2026-11-02",
              "slot" => "lunch",
              "recipe_id" => r.rice_pot.id
            }},
           {"edit_workspace",
            %{
              "action" => "pin",
              "date" => "2026-11-02",
              "slot" => "dinner",
              "recipe_id" => r.bean_bowl.id
            }},
           {"edit_workspace", %{"action" => "exclude", "recipe_id" => r.bean_bowl.id}}
         ]},
        {:text, "ok"}
      ]

      {session_id, pid} = start!(h, script)
      results = run_turn!(session_id, pid, "Edit")

      assert Enum.map(results(results, "edit_workspace"), &(&1["error"] || &1["status"])) ==
               ["ok", "recipe_excluded", "ok", "recipe_pinned"]
    end
  end

  describe "run_optimizer over the Workspace" do
    test "Pins, Excluded Recipes, the variety cap and prior meals reach the optimizer",
         %{household: h, recipes: r} do
      scheduled_meal!(h, ~D[2026-11-01], :lunch, r.bean_bowl)

      script = [
        edit(%{
          "action" => "pin",
          "date" => "2026-11-03",
          "slot" => "dinner",
          "recipe_id" => r.chicken_rice.id
        }),
        edit(%{"action" => "exclude", "recipe_id" => r.rice_pot.id}),
        edit(%{"action" => "set_variety_cap", "variety_cap" => 4}),
        {:tool_calls, [{"run_optimizer", %{}}]},
        {:text, "ok"}
      ]

      {session_id, pid} = start!(h, script)
      _ = run_turn!(session_id, pid, "Plan")

      assert_received {:optimizer_payload, payload}

      assert payload["fixed_meals"] == [
               %{"day" => "2026-11-03", "slot" => "dinner", "recipe_id" => r.chicken_rice.id}
             ]

      assert payload["excluded_recipe_ids"] == [r.rice_pot.id]
      assert payload["constraints"]["variety_cap"] == 4

      assert payload["prior_meals"] == [
               %{"day" => "2026-11-01", "slot" => "lunch", "recipe_id" => r.bean_bowl.id}
             ]

      dinner_ids = Enum.map(payload["candidates_by_slot"]["dinner"], & &1["recipe_id"])
      assert r.chicken_rice.id in dinner_ids
      refute r.rice_pot.id in dinner_ids
    end

    test "a pinned recipe outside the searched candidates still reaches its slot",
         %{household: h} do
      # More recipes than the optimizer candidates of one slot (50), all
      # sorting before the pinned one.
      oat = ingredient!("Fictitious oat")
      for i <- 1..50, do: recipe!("Aa filler #{String.pad_leading("#{i}", 2, "0")}", [oat])
      late = recipe!("Zz late porridge", [oat])

      script = [
        edit(%{
          "action" => "pin",
          "date" => "2026-11-02",
          "slot" => "lunch",
          "recipe_id" => late.id
        }),
        {:tool_calls, [{"run_optimizer", %{}}]},
        {:text, "ok"}
      ]

      {session_id, pid} = start!(h, script)
      _ = run_turn!(session_id, pid, "Plan")

      assert_received {:optimizer_payload, payload}
      assert late.id in Enum.map(payload["candidates_by_slot"]["lunch"], & &1["recipe_id"])
    end

    test "the optimizer's Deviations reach the agent", %{household: h} do
      deviation = %{"goal" => "budget", "priority" => 1, "amount" => 800}

      with_deviation = fn payload ->
        {:ok, %{"meals" => meals}} = FakeOptimizer.first_candidates(payload)
        {:ok, %{"meals" => meals, "deviations" => [deviation], "optimality" => "optimal"}}
      end

      {session_id, pid} =
        start!(h, [{:tool_calls, [{"run_optimizer", %{}}]}, {:text, "ok"}],
          result: with_deviation
        )

      results = run_turn!(session_id, pid, "Plan")

      assert %{"status" => "ok", "deviations" => [^deviation], "optimality" => "optimal"} =
               last_result(results, "run_optimizer")
    end

    test "a re-optimization keeps every meal that was not released", %{household: h, recipes: r} do
      script =
        plan_and_present() ++
          [
            edit(%{"action" => "release", "date" => "2026-11-02", "slot" => "lunch"}),
            {:tool_calls, [{"run_optimizer", %{}}]},
            {:text, "ok"}
          ]

      {session_id, pid} = start!(h, script)
      _ = run_turn!(session_id, pid, "Plan, then change Monday lunch")

      assert_received {:optimizer_payload, _first}
      assert_received {:optimizer_payload, second}

      assert Enum.sort_by(second["fixed_meals"], &{&1["day"], &1["slot"]}) == [
               %{"day" => "2026-11-02", "slot" => "dinner", "recipe_id" => r.lentil_stew.id},
               %{"day" => "2026-11-03", "slot" => "dinner", "recipe_id" => r.lentil_stew.id},
               %{"day" => "2026-11-03", "slot" => "lunch", "recipe_id" => r.lentil_stew.id}
             ]
    end

    test "an optimizer reply that moves a fixed meal is rejected", %{household: h, recipes: r} do
      script = [
        edit(%{
          "action" => "pin",
          "date" => "2026-11-02",
          "slot" => "lunch",
          "recipe_id" => r.bean_bowl.id
        }),
        {:tool_calls, [{"run_optimizer", %{}}]},
        present(),
        {:text, "ok"}
      ]

      {session_id, pid} =
        start!(h, script, result: FakeOptimizer.everywhere(r.lentil_stew.id))

      results = run_turn!(session_id, pid, "Plan")

      assert %{"error" => "optimizer_failed", "reason" => "fixed_meal_moved"} =
               last_result(results, "run_optimizer")

      assert %{"error" => "no_plan_to_present"} = last_result(results, "present_proposal")
      refute_received {:planning_agent_event, ^session_id, %{"type" => "proposal"}}
    end

    test "an edit discards the draft until the optimizer runs again", %{household: h, recipes: r} do
      # The fake optimizer plans the first candidate, the lentil stew, everywhere.
      script = [
        {:tool_calls, [{"run_optimizer", %{}}]},
        edit(%{"action" => "exclude", "recipe_id" => r.lentil_stew.id}),
        present(),
        {:tool_calls, [{"run_optimizer", %{}}]},
        edit(%{
          "action" => "pin",
          "date" => "2026-11-02",
          "slot" => "lunch",
          "recipe_id" => r.bean_bowl.id
        }),
        present(),
        {:tool_calls, [{"run_optimizer", %{}}]},
        present(),
        {:text, "ok"}
      ]

      {session_id, pid} = start!(h, script)
      results = run_turn!(session_id, pid, "Plan without the stew, Monday lunch the bean bowl")

      assert Enum.map(results(results, "edit_workspace"), & &1["status"]) == ["ok", "ok"]

      assert [%{"error" => "no_plan_to_present"}, %{"error" => "no_plan_to_present"}, last] =
               results(results, "present_proposal")

      assert %{"status" => "valid"} = last

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "proposal", "meals" => meals}}

      plan = plan_by_slot(meals)
      assert plan[{"2026-11-02", "lunch"}] == r.bean_bowl.id
      refute r.lentil_stew.id in Map.values(plan)
    end

    test "redo the whole week releases every meal but keeps the session's Pins",
         %{household: h, recipes: r} do
      script =
        [
          edit(%{
            "action" => "pin",
            "date" => "2026-11-02",
            "slot" => "lunch",
            "recipe_id" => r.bean_bowl.id
          })
        ] ++
          plan_and_present() ++
          [
            edit(%{"action" => "release_all"}),
            {:tool_calls, [{"run_optimizer", %{}}]},
            {:tool_calls, [{"get_workspace", %{}}]},
            {:text, "ok"}
          ]

      {session_id, pid} = start!(h, script)
      results = run_turn!(session_id, pid, "Redo the whole week")

      pin = %{"day" => "2026-11-02", "slot" => "lunch", "recipe_id" => r.bean_bowl.id}

      assert_received {:optimizer_payload, first}
      assert first["fixed_meals"] == [pin]
      assert_received {:optimizer_payload, second}
      assert second["fixed_meals"] == [pin]

      assert %{"released_count" => 3, "still_pinned" => [%{"date" => "2026-11-02"}]} =
               last_result(results, "edit_workspace")

      assert [%{"recipe_id" => bean}] = last_result(results, "get_workspace")["pins"]
      assert bean == r.bean_bowl.id
      assert length(last_result(results, "get_workspace")["released"]) == 3
    end
  end

  describe "refinement" do
    test "a two-meal refinement leaves the other meals untouched", %{household: h, recipes: r} do
      # Honours fixed meals and picks the last candidate for every free meal,
      # so a released meal visibly changes.
      honouring = fn payload ->
        fixed = Map.new(payload["fixed_meals"] || [], &{{&1["day"], &1["slot"]}, &1["recipe_id"]})

        meals =
          for day <- payload["days"], slot <- payload["slots"] do
            recipe_id =
              Map.get_lazy(fixed, {day, slot}, fn ->
                List.last(payload["candidates_by_slot"][slot])["recipe_id"]
              end)

            %{"day" => day, "slot" => slot, "recipe_id" => recipe_id}
          end

        {:ok, %{"meals" => meals}}
      end

      first_plan = fn payload ->
        if payload["fixed_meals"] == [],
          do: FakeOptimizer.first_candidates(payload),
          else: honouring.(payload)
      end

      script =
        plan_and_present() ++
          [{:text, "Here is your plan."}] ++
          [
            edit(%{"action" => "release", "date" => "2026-11-02", "slot" => "lunch"}),
            edit(%{"action" => "release", "date" => "2026-11-03", "slot" => "dinner"}),
            {:tool_calls, [{"run_optimizer", %{}}]},
            present(),
            {:text, "I changed Monday lunch and Tuesday dinner."}
          ]

      {session_id, pid} =
        start!(h, script, range: {@monday, @wednesday}, result: first_plan)

      _ = run_turn!(session_id, pid, "Plan Monday to Wednesday")

      assert_received {:planning_agent_event, ^session_id,
                       %{"type" => "proposal", "status" => "valid", "meals" => first}}

      flush_payloads()
      _ = run_turn!(session_id, pid, "Change Monday lunch and Tuesday dinner")

      assert_received {:planning_agent_event, ^session_id,
                       %{"type" => "proposal", "status" => "valid", "meals" => second}}

      before = plan_by_slot(first)
      after_refinement = plan_by_slot(second)
      released = [{"2026-11-02", "lunch"}, {"2026-11-03", "dinner"}]

      assert map_size(after_refinement) == 6
      assert Map.drop(after_refinement, released) == Map.drop(before, released)

      for key <- released do
        assert before[key] == r.lentil_stew.id
        refute after_refinement[key] == before[key]
      end
    end
  end

  describe "single-meal change (issue #148)" do
    # Like the real optimizer: keeps fixed meals, never takes an excluded
    # recipe or an avoided one, and otherwise picks the first candidate, so a
    # Released Meal stays the same unless code tells the optimizer to change it.
    defp first_allowed(payload) do
      fixed = Map.new(payload["fixed_meals"] || [], &{{&1["day"], &1["slot"]}, &1["recipe_id"]})
      excluded = MapSet.new(payload["excluded_recipe_ids"] || [])

      avoided =
        MapSet.new(payload["avoided_meals"] || [], &{&1["day"], &1["slot"], &1["recipe_id"]})

      meals =
        for day <- payload["days"], slot <- payload["slots"] do
          recipe_id =
            Map.get_lazy(fixed, {day, slot}, fn ->
              payload["candidates_by_slot"][slot]
              |> Enum.map(& &1["recipe_id"])
              |> Enum.find(&(not MapSet.member?(excluded, &1) and {day, slot, &1} not in avoided))
            end)

          %{"day" => day, "slot" => slot, "recipe_id" => recipe_id}
        end

      if Enum.any?(meals, &is_nil(&1["recipe_id"])),
        do: {:error, :infeasible, %{"causes" => [%{"cause" => "avoided_meal"}]}},
        else: {:ok, %{"meals" => meals}}
    end

    defp change_tuesday_dinner!(h, change_steps) do
      script =
        plan_and_present() ++
          [{:text, "Here is your plan."}] ++
          change_steps ++ [present(), {:text, "I changed Tuesday dinner."}]

      {session_id, pid} =
        start!(h, script, range: {@monday, @wednesday}, result: &first_allowed/1)

      _ = run_turn!(session_id, pid, "Plan Monday to Wednesday")

      assert_received {:planning_agent_event, ^session_id,
                       %{"type" => "proposal", "status" => "valid", "meals" => first}}

      flush_payloads()
      results = run_turn!(session_id, pid, "Change Tuesday dinner and keep every other meal")
      assert_received {:optimizer_payload, payload}

      assert_received {:planning_agent_event, ^session_id,
                       %{"type" => "proposal", "status" => "valid", "meals" => second}}

      {plan_by_slot(first), plan_by_slot(second), payload, results}
    end

    test "a released meal must change: the next run avoids its previous recipe there only",
         %{household: h, recipes: r} do
      {before, replaced, payload, _results} =
        change_tuesday_dinner!(h, [
          edit(%{"action" => "release", "date" => "2026-11-03", "slot" => "dinner"}),
          {:tool_calls, [{"run_optimizer", %{}}]}
        ])

      assert payload["avoided_meals"] == [
               %{"day" => "2026-11-03", "slot" => "dinner", "recipe_id" => r.lentil_stew.id}
             ]

      key = {"2026-11-03", "dinner"}
      assert map_size(replaced) == 6
      refute replaced[key] == before[key]
      assert Map.delete(replaced, key) == Map.delete(before, key)
    end

    test "excluding the released meal's recipe for one run keeps the meals that use it",
         %{household: h, recipes: r} do
      # Every kept meal uses the lentil stew too; excluding it for the run
      # must not make the kept meals infeasible (battery A10).
      {before, replaced, payload, results} =
        change_tuesday_dinner!(h, [
          edit(%{"action" => "release", "date" => "2026-11-03", "slot" => "dinner"}),
          {:tool_calls,
           [{"run_optimizer", %{"exclude_recipe_ids" => [r.lentil_stew.id, r.bean_bowl.id]}}]}
        ])

      assert %{"status" => "ok"} = last_result(results, "run_optimizer")
      assert payload["excluded_recipe_ids"] == [r.bean_bowl.id]
      free = payload["avoided_meals"] |> Enum.map(&{&1["day"], &1["slot"], &1["recipe_id"]})
      assert free == [{"2026-11-03", "dinner", r.lentil_stew.id}]

      key = {"2026-11-03", "dinner"}
      refute replaced[key] in [before[key], r.bean_bowl.id]
      assert Map.delete(replaced, key) == Map.delete(before, key)
    end

    test "redo the whole week does not force every meal to change", %{household: h} do
      script =
        plan_and_present() ++
          [edit(%{"action" => "release_all"}), {:tool_calls, [{"run_optimizer", %{}}]}] ++
          [{:text, "ok"}]

      {session_id, pid} = start!(h, script)
      _ = run_turn!(session_id, pid, "Plan, then redo the whole week")

      assert_received {:optimizer_payload, _first}
      assert_received {:optimizer_payload, second}
      assert second["avoided_meals"] == []
    end

    test "an optimizer reply that keeps an avoided recipe is rejected",
         %{household: h, recipes: r} do
      script =
        plan_and_present() ++
          [
            edit(%{"action" => "release", "date" => "2026-11-02", "slot" => "lunch"}),
            {:tool_calls, [{"run_optimizer", %{}}]},
            {:text, "ok"}
          ]

      {session_id, pid} = start!(h, script, result: FakeOptimizer.everywhere(r.lentil_stew.id))
      results = run_turn!(session_id, pid, "Plan, then change Monday lunch")

      assert %{"error" => "optimizer_failed", "reason" => "released_meal_unchanged"} =
               last_result(results, "run_optimizer")
    end
  end
end
