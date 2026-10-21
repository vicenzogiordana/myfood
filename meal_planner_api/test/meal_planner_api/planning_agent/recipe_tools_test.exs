defmodule MealPlannerApi.PlanningAgent.RecipeToolsTest do
  @moduledoc """
  Recipe Drafts through the session module with the scripted model (issue
  #104, spec #93 user stories 13 and 36–39): `create_recipe` builds a Draft
  from catalog Ingredients only, with nutrition and cost computed by code,
  and `get_recipe` reads a recipe or a Draft with its nutrition completeness.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Catalog.Recipe
  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.RecipeDraft
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    # Per 100 g: 350 kcal, 12 g protein, 70 g carbs, 1.5 g fat.
    pasta =
      ingredient!("Fictitious pasta", [], %{
        calories_per_100: 350,
        protein_g_per_100: Decimal.new("12"),
        carbs_g_per_100: Decimal.new("70"),
        fat_g_per_100: Decimal.new("1.5")
      })

    # Per 100 g: 20 kcal, 1 g protein, 4 g carbs, 0.2 g fat.
    tomato =
      ingredient!("Fictitious tomato", [], %{
        calories_per_100: 20,
        protein_g_per_100: Decimal.new("1"),
        carbs_g_per_100: Decimal.new("4"),
        fat_g_per_100: Decimal.new("0.2")
      })

    # No nutrition data at all.
    herb = ingredient!("Fictitious herb")

    %{household: household, pasta: pasta, tomato: tomato, herb: herb}
  end

  defp start!(household, script) do
    attrs = session_attrs(household, household.owner, {@monday, @monday})

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, []},
        subscriber: self()
      )

    {session_id, pid}
  end

  # Runs the scripted tool steps in one turn and returns every tool result
  # the model received, in order.
  defp run_tools(household, steps) do
    {session_id, pid} = start!(household, steps ++ [{:text, "done"}])
    :ok = Session.send_message(pid, "Go")
    assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

    requests = collect_requests([])
    %{messages: messages} = List.last(requests)
    for %{role: :tool_result, content: content} <- messages, do: content
  end

  defp collect_requests(acc) do
    receive do
      {:scripted_model_request, request} -> collect_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A step calling get_recipe on the Draft the previous tool result returned.
  defp get_created_recipe do
    fn %{messages: messages} ->
      %{role: :tool_result, content: %{"recipe_id" => id}} = List.last(messages)
      {:tool_calls, [{"get_recipe", %{"recipe_id" => id}}]}
    end
  end

  defp draft_args(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Fictitious tomato pasta",
        "servings" => 2,
        "slots" => ["lunch", "dinner"],
        "origin" => "ai_created",
        "ingredients" => [
          %{"ingredient" => ctx.pasta.name, "quantity" => 200, "unit" => "g"},
          %{"ingredient" => String.upcase(ctx.tomato.name), "quantity" => 300, "unit" => "g"}
        ],
        "steps" => ["Boil the pasta.", "Add the tomato."]
      },
      overrides
    )
  end

  describe "create_recipe" do
    test "drafts a recipe from catalog Ingredients with code-computed nutrition and cost",
         %{household: h} = ctx do
      product!(ctx.pasta, package: {500_000, :g}, price_cents: 1_000)
      product!(ctx.tomato, package: {1_000_000, :g}, price_cents: 2_000)

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", draft_args(ctx)}]}])

      assert result["status"] == "drafted"
      assert result["draft"] == true
      assert result["origin"] == "ai_created"
      assert result["outcome"] == "complete"
      assert {:ok, _} = Ecto.UUID.cast(result["recipe_id"])

      assert [
               %{"ingredient" => pasta_name, "quantity_milli" => 200_000, "unit" => "g"},
               %{"ingredient" => tomato_name, "quantity_milli" => 300_000, "unit" => "g"}
             ] = result["ingredients"]

      assert pasta_name == ctx.pasta.name
      assert tomato_name == ctx.tomato.name
      assert result["steps"] == ["Boil the pasta.", "Add the tomato."]

      # (700 + 60) kcal / 2 servings; (24 + 3) g protein / 2; (140 + 12) g
      # carbs / 2; (3 + 0.6) g fat / 2.
      assert result["nutrition"] == %{
               "per_serving" => %{
                 "calories" => 380,
                 "protein_g" => 13.5,
                 "carbs_g" => 76.0,
                 "fat_g" => 1.8
               },
               "complete" => true,
               "missing" => []
             }

      # 200 g of a 1000 cents / 500 g package = 400; 300 g of 2000 / 1 kg = 600.
      assert result["cost"] == %{
               "total_cents" => 1_000,
               "total" => "ARS 10,00",
               "per_serving_cents" => 500,
               "per_serving" => "ARS 5,00",
               "currency" => "ARS",
               "complete" => true,
               "missing_prices" => []
             }

      # A Draft is never persisted by the tool.
      refute Repo.get_by(Recipe, name: "Fictitious tomato pasta")
    end

    # Water, salt and pepper are assumed at home (issue #162): they need no
    # catalog entry, never block the Draft and are never priced or bought.
    test "staples need no catalog entry and are never priced", %{household: h} = ctx do
      product!(ctx.pasta, package: {500_000, :g}, price_cents: 1_000)
      product!(ctx.tomato, package: {1_000_000, :g}, price_cents: 2_000)

      args =
        draft_args(ctx, %{
          "ingredients" =>
            draft_args(ctx)["ingredients"] ++
              [
                %{"ingredient" => "Water", "quantity" => 500, "unit" => "ml"},
                %{"ingredient" => " sal ", "quantity" => 5, "unit" => "g"},
                %{"ingredient" => "Pimienta negra", "quantity" => 1, "unit" => "g"}
              ]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["status"] == "drafted"
      assert result["outcome"] == "complete"

      assert Enum.map(result["ingredients"], & &1["ingredient"]) == [
               ctx.pasta.name,
               ctx.tomato.name
             ]

      assert result["staples"] == [
               %{"ingredient" => "Water", "quantity_milli" => 500_000, "unit" => "ml"},
               %{"ingredient" => "sal", "quantity_milli" => 5_000, "unit" => "g"},
               %{"ingredient" => "Pimienta negra", "quantity_milli" => 1_000, "unit" => "g"}
             ]

      assert result["nutrition"]["complete"] == true
      assert result["cost"]["total_cents"] == 1_000
      assert result["cost"]["complete"] == true
      assert result["cost"]["missing_prices"] == []
    end

    test "a staple in the catalog is still never priced", %{household: h} = ctx do
      salt = ingredient!("Salt")
      product!(salt, package: {1_000_000, :g}, price_cents: 9_999)
      product!(ctx.pasta, package: {500_000, :g}, price_cents: 1_000)
      product!(ctx.tomato, package: {1_000_000, :g}, price_cents: 2_000)

      args =
        draft_args(ctx, %{
          "ingredients" =>
            draft_args(ctx)["ingredients"] ++
              [%{"ingredient" => "salt", "quantity" => 5, "unit" => "g"}]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["status"] == "drafted"
      refute Enum.any?(result["ingredients"], &(&1["ingredient"] == "Salt"))
      assert [%{"ingredient" => "salt"}] = result["staples"]
      assert result["cost"]["total_cents"] == 1_000
    end

    test "a staple listed twice is a duplicate", %{household: h} = ctx do
      args =
        draft_args(ctx, %{
          "ingredients" =>
            draft_args(ctx)["ingredients"] ++
              [
                %{"ingredient" => "agua", "quantity" => 100, "unit" => "ml"},
                %{"ingredient" => "Agua", "quantity" => 200, "unit" => "ml"}
              ]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])
      assert %{"error" => "invalid_recipe", "reason" => "duplicate_ingredient"} = result
    end

    test "rejects unknown Ingredients instead of inventing them", %{household: h} = ctx do
      args =
        draft_args(ctx, %{
          "ingredients" => [
            %{"ingredient" => ctx.pasta.name, "quantity" => 200, "unit" => "g"},
            %{"ingredient" => "Imaginary truffle", "quantity" => 10, "unit" => "g"}
          ]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["error"] == "unknown_ingredients"
      assert result["ingredients"] == ["Imaginary truffle"]
      assert result["outcome"] == "failure"
      refute Map.has_key?(result, "recipe_id")
    end

    test "lists close catalog matches for unknown Ingredients (issue #154)",
         %{household: h} = ctx do
      {:ok, wheat} = Catalog.create_ingredient(%{name: "Harina de trigo", category: :otros})
      {:ok, raising} = Catalog.create_ingredient(%{name: "Harina leudante", category: :otros})
      _unrelated = ingredient!("Fictitious lemon")

      args =
        draft_args(ctx, %{
          "ingredients" => [
            %{"ingredient" => "harina 000", "quantity" => 500, "unit" => "g"},
            %{"ingredient" => "Imaginary truffle", "quantity" => 10, "unit" => "g"}
          ]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["error"] == "unknown_ingredients"
      matches = Map.new(result["close_matches"], &{&1["ingredient"], &1["matches"]})

      assert Enum.sort(matches["harina 000"]) == [wheat.name, raising.name]
      refute "Fictitious lemon" in matches["harina 000"]
      assert matches["Imaginary truffle"] == []
      assert result["hint"] =~ "close_matches"
    end

    # Issue #164: one clear candidate is used, and the substitution reported.
    test "an unknown Ingredient with one clear close match resolves to it and is reported",
         %{household: h} = ctx do
      {:ok, tomato} = Catalog.create_ingredient(%{name: "Tomate perita", category: :otros})
      {:ok, cheese} = Catalog.create_ingredient(%{name: "Muzzarella", category: :otros})

      args =
        draft_args(ctx, %{
          "ingredients" => [
            %{"ingredient" => ctx.pasta.name, "quantity" => 200, "unit" => "g"},
            %{"ingredient" => "Tomate", "quantity" => 300, "unit" => "g"},
            %{"ingredient" => "Queso mozzarella", "quantity" => 150, "unit" => "g"}
          ]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["status"] == "drafted"

      assert Enum.map(result["ingredients"], & &1["ingredient"]) ==
               [ctx.pasta.name, tomato.name, cheese.name]

      assert result["resolved"] == [
               %{"requested" => "Tomate", "used" => "Tomate perita"},
               %{"requested" => "Queso mozzarella", "used" => "Muzzarella"}
             ]

      assert result["resolved_note"] =~ "only when the meaning could differ"
    end

    # Issue #164: two close candidates are for the agent to choose from.
    test "two close candidates still reject the Draft, retryable and not missing",
         %{household: h} = ctx do
      {:ok, plum} = Catalog.create_ingredient(%{name: "Tomate perita", category: :otros})
      {:ok, cherry} = Catalog.create_ingredient(%{name: "Tomate cherry", category: :otros})

      args =
        draft_args(ctx, %{
          "ingredients" => [%{"ingredient" => "Tomate", "quantity" => 300, "unit" => "g"}]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["error"] == "unknown_ingredients"
      [%{"ingredient" => "Tomate", "matches" => matches}] = result["close_matches"]
      assert plum.name in matches and cherry.name in matches
      assert result["missing_from_catalog"] == []
      refute result["hint"] =~ "not in the catalog"
      refute Map.has_key?(result, "resolved")
    end

    test "an unambiguous spelling variant resolves to its catalog name and is reported",
         %{household: h} = ctx do
      {:ok, lemon} = Catalog.create_ingredient(%{name: "Limón", category: :otros})

      args =
        draft_args(ctx, %{
          "ingredients" => [
            %{"ingredient" => ctx.pasta.name, "quantity" => 200, "unit" => "g"},
            %{"ingredient" => "limones", "quantity" => 50, "unit" => "g"}
          ]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["status"] == "drafted"
      assert Enum.map(result["ingredients"], & &1["ingredient"]) == [ctx.pasta.name, lemon.name]
      assert result["renamed_ingredients"] == [%{"requested" => "limones", "catalog" => "Limón"}]
    end

    # Issue #158: guessing other names for an Ingredient the catalog does not
    # have only burns attempts until the no-progress limit cuts the run.
    test "an Ingredient without close matches is named as missing and not to be guessed",
         %{household: h} = ctx do
      args =
        draft_args(ctx, %{
          "ingredients" => [
            %{"ingredient" => "Fictitious tomatoes", "quantity" => 200, "unit" => "g"},
            %{"ingredient" => "Imaginary truffle", "quantity" => 10, "unit" => "g"}
          ]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["error"] == "unknown_ingredients"
      assert result["missing_from_catalog"] == ["Imaginary truffle"]
      assert result["hint"] =~ "Imaginary truffle is not in the catalog"
      assert result["hint"] =~ "Do not retry it with other names"
      assert result["hint"] =~ "tell the household"
      assert result["hint"] =~ "plan the rest"
    end

    test "labels nutrition and cost partial when data is missing, never zero",
         %{household: h} = ctx do
      product!(ctx.pasta, package: {500_000, :g}, price_cents: 1_000)

      args =
        draft_args(ctx, %{
          "ingredients" => [
            %{"ingredient" => ctx.pasta.name, "quantity" => 200, "unit" => "g"},
            %{"ingredient" => ctx.herb.name, "quantity" => 5, "unit" => "g"}
          ]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["outcome"] == "partial"
      assert "nutrition" in result["missing"]
      assert "prices" in result["missing"]

      # The herb has no nutrition: no total is claimed for any nutrient.
      assert result["nutrition"]["complete"] == false
      assert result["nutrition"]["missing"] == [ctx.herb.name]

      assert result["nutrition"]["per_serving"] == %{
               "calories" => nil,
               "protein_g" => nil,
               "carbs_g" => nil,
               "fat_g" => nil
             }

      # Only the priced part is counted; the missing price is named.
      assert result["cost"]["complete"] == false
      assert result["cost"]["total_cents"] == 400

      assert [%{"ingredient" => herb_name, "reason" => "no_stored_price"}] =
               result["cost"]["missing_prices"]

      assert herb_name == ctx.herb.name
    end

    # Issue #164: "Cebolla, 1 unit" while onions are sold by weight.
    test "a missing price in an unsold unit names the units it is sold in",
         %{household: h} = ctx do
      onion = ingredient!("Fictitious onion")
      product!(onion, package: {1_000_000, :g}, price_cents: 900)

      args =
        draft_args(ctx, %{
          "ingredients" => [%{"ingredient" => onion.name, "quantity" => 1, "unit" => "unit"}]
        })

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert [missing] = result["cost"]["missing_prices"]
      assert missing["reason"] == "no_matching_presentation"
      assert missing["sold_in"] == ["g"]
      assert missing["hint"] =~ "restate the quantity in g"
      assert missing["hint"] =~ "never converts units"
    end

    test "a missing price without any stored price names no units", %{household: h} = ctx do
      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", draft_args(ctx)}]}])

      assert Enum.all?(result["cost"]["missing_prices"], &(not Map.has_key?(&1, "sold_in")))
    end

    test "rejects an AI-created Draft that breaks a household Restriction", %{household: h} do
      beef = ingredient!("Fictitious beef", [:contains_meat])
      diet!(h.owner, :vegetarian)

      args = %{
        "name" => "Fictitious beef stew",
        "servings" => 2,
        "slots" => ["dinner"],
        "origin" => "ai_created",
        "ingredients" => [%{"ingredient" => beef.name, "quantity" => 300, "unit" => "g"}],
        "steps" => ["Stew it."]
      }

      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["error"] == "restriction_conflict"
    end

    test "rejects malformed recipes with a reason", %{household: h} = ctx do
      [no_name, bad_unit, bad_slot] =
        run_tools(h, [
          {:tool_calls,
           [
             {"create_recipe", draft_args(ctx, %{"name" => ""})},
             {"create_recipe",
              draft_args(ctx, %{
                "ingredients" => [
                  %{"ingredient" => ctx.pasta.name, "quantity" => 1, "unit" => "cup"}
                ]
              })},
             {"create_recipe", draft_args(ctx, %{"slots" => ["brunch"]})}
           ]}
        ])

      assert %{"error" => "invalid_recipe", "reason" => "name_required"} = no_name
      assert %{"error" => "invalid_recipe", "reason" => "invalid_ingredient"} = bad_unit
      assert %{"error" => "invalid_recipe", "reason" => "invalid_slots"} = bad_slot
    end

    test "discloses the Draft to the Member as AI-created", %{household: h} = ctx do
      {session_id, pid} =
        start!(h, [{:tool_calls, [{"create_recipe", draft_args(ctx)}]}, {:text, "done"}])

      :ok = Session.send_message(pid, "Go")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "recipe_draft", "origin" => "ai_created"} = event}

      assert event["name"] == "Fictitious tomato pasta"
      assert is_binary(event["recipe_id"])
      assert %{"complete" => true} = event["nutrition"]
    end
  end

  describe "revising a Draft (issue #154)" do
    # A step re-creating the Draft the previous tool result returned.
    defp revise_created(args) do
      fn %{messages: messages} ->
        %{role: :tool_result, content: %{"recipe_id" => id}} = List.last(messages)
        {:tool_calls, [{"create_recipe", Map.put(args, "replaces_recipe_id", id)}]}
      end
    end

    test "re-creating a Draft with the same name and origin revises it", %{household: h} = ctx do
      first = draft_args(ctx)
      again = draft_args(ctx, %{"name" => "  fictitious TOMATO pasta ", "servings" => 4})

      [drafted, revised] =
        run_tools(h, [
          {:tool_calls, [{"create_recipe", first}]},
          {:tool_calls, [{"create_recipe", again}]}
        ])

      assert drafted["status"] == "drafted"
      assert revised["status"] == "revised"
      assert revised["recipe_id"] == drafted["recipe_id"]
      assert revised["servings"] == 4
    end

    test "replaces_recipe_id revises the named Draft, whatever its new name",
         %{household: h} = ctx do
      [drafted, revised, read] =
        run_tools(h, [
          {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
          revise_created(draft_args(ctx, %{"name" => "Fictitious pasta al pomodoro"})),
          get_created_recipe()
        ])

      assert revised["status"] == "revised"
      assert revised["recipe_id"] == drafted["recipe_id"]
      assert read["recipe_id"] == drafted["recipe_id"]
      assert read["name"] == "Fictitious pasta al pomodoro"
    end

    test "revisions leave one Draft: they never count toward the Draft limit",
         %{household: h} = ctx do
      calls = List.duplicate({"create_recipe", draft_args(ctx)}, RecipeDraft.max_drafts() + 1)
      results = run_tools(h, [{:tool_calls, calls}])

      assert length(results) == RecipeDraft.max_drafts() + 1
      assert results |> Enum.map(& &1["recipe_id"]) |> Enum.uniq() |> length() == 1
      refute Enum.any?(results, &(&1["error"] == "draft_limit_reached"))
    end

    test "a Draft of the other origin with the same name is a different Draft",
         %{household: h} = ctx do
      [ai, dictated] =
        run_tools(h, [
          {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
          {:tool_calls, [{"create_recipe", draft_args(ctx, %{"origin" => "user_created"})}]}
        ])

      assert dictated["status"] == "drafted"
      assert dictated["recipe_id"] != ai["recipe_id"]
    end

    test "an unknown replaces_recipe_id is refused", %{household: h} = ctx do
      args = Map.put(draft_args(ctx), "replaces_recipe_id", Ecto.UUID.generate())
      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", args}]}])

      assert result["error"] == "draft_not_found"
    end

    # Issue #164: Haiku sent `"replaces_recipe_id": ""` for a new Draft.
    test "an empty replaces_recipe_id is absent: a new Draft is created", %{household: h} = ctx do
      calls =
        for {blank, name} <- [{"", "Fictitious pasta one"}, {"   ", "Fictitious pasta two"}] do
          {"create_recipe", draft_args(ctx, %{"name" => name, "replaces_recipe_id" => blank})}
        end

      results = run_tools(h, [{:tool_calls, calls}])

      assert Enum.map(results, & &1["status"]) == ["drafted", "drafted"]
      assert results |> Enum.map(& &1["recipe_id"]) |> Enum.uniq() |> length() == 2
    end

    test "a partial Draft tells the agent it is usable as is", %{household: h} = ctx do
      [result] = run_tools(h, [{:tool_calls, [{"create_recipe", draft_args(ctx)}]}])

      assert result["outcome"] == "partial"
      assert result["missing"] == ["prices"]
      assert result["usable"] == true
      assert result["note"] =~ "do not re-create"
    end
  end

  describe "get_recipe" do
    test "returns a Draft of the Workspace with its nutrition completeness",
         %{household: h} = ctx do
      [_created, read] =
        run_tools(h, [
          {:tool_calls, [{"create_recipe", draft_args(ctx)}]},
          get_created_recipe()
        ])

      assert read["name"] == "Fictitious tomato pasta"
      assert read["origin"] == "ai_created"
      assert read["draft"] == true
      assert read["steps"] == ["Boil the pasta.", "Add the tomato."]
      assert read["nutrition"]["complete"] == true
    end

    test "returns ingredients, quantities, steps and nutrition completeness of a recipe",
         %{household: h} = ctx do
      recipe =
        recipe!("Fictitious stored pasta", [ctx.pasta, ctx.tomato],
          quantities: %{ctx.pasta.id => {150_000, :g}, ctx.tomato.id => {1_000, :unit}}
        )

      {:ok, _} =
        Catalog.add_recipe_step(%{recipe_id: recipe.id, step_number: 2, instructions: "Serve."})

      {:ok, _} =
        Catalog.add_recipe_step(%{recipe_id: recipe.id, step_number: 1, instructions: "Cook."})

      [result] = run_tools(h, [{:tool_calls, [{"get_recipe", %{"recipe_id" => recipe.id}}]}])

      assert result["recipe_id"] == recipe.id
      assert result["origin"] == "traditional"
      assert result["draft"] == false
      assert result["servings"] == 2
      assert result["steps"] == ["Cook.", "Serve."]

      assert Enum.sort_by(result["ingredients"], & &1["quantity_milli"]) == [
               %{"ingredient" => ctx.tomato.name, "quantity_milli" => 1_000, "unit" => "unit"},
               %{"ingredient" => ctx.pasta.name, "quantity_milli" => 150_000, "unit" => "g"}
             ]

      # The fixture stores calories only: macros are reported missing.
      assert result["nutrition"] == %{
               "per_serving" => %{
                 "calories" => 500,
                 "protein_g" => nil,
                 "carbs_g" => nil,
                 "fat_g" => nil
               },
               "complete" => false,
               "missing" => ["protein_g", "carbs_g", "fat_g"]
             }

      assert result["outcome"] == "partial"
    end

    test "does not reveal recipes of another Household or breaking a Restriction",
         %{household: h} do
      other = household!("Other Fictitious Household")
      private = recipe!("Other private recipe", [], account_id: other.account_id)

      fish = ingredient!("Fictitious fish", [:contains_fish])
      fish_recipe = recipe!("Fictitious fish dish", [fish])
      diet!(h.owner, :vegetarian)

      [hidden, restricted, malformed] =
        run_tools(h, [
          {:tool_calls,
           [
             {"get_recipe", %{"recipe_id" => private.id}},
             {"get_recipe", %{"recipe_id" => fish_recipe.id}},
             {"get_recipe", %{"recipe_id" => "not-a-uuid"}}
           ]}
        ])

      assert hidden["error"] == "recipe_not_found"
      assert restricted["error"] == "recipe_not_found"
      assert malformed["error"] == "recipe_not_found"
    end
  end

  describe "search_recipes" do
    test "shows the Recipe Origin of every result", %{household: h} = ctx do
      recipe!("Fictitious origin pasta", [ctx.pasta])

      {:ok, _} =
        Catalog.create_recipe(%{
          name: "Fictitious origin family pasta",
          source: :user_created,
          account_id: h.account_id,
          servings: 2,
          suitable_for_slots: ["lunch"]
        })

      [result] = run_tools(h, [{:tool_calls, [{"search_recipes", %{"query" => "origin"}}]}])

      assert Enum.map(result["recipes"], &{&1["name"], &1["origin"]}) == [
               {"Fictitious origin family pasta", "user_created"},
               {"Fictitious origin pasta", "traditional"}
             ]
    end
  end
end
