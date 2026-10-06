defmodule MealPlannerApi.Services.RecipeLifecycleTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.{Catalog, Planning}
  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.{CookingService, RecipeService, RecipeVersions, ShoppingRebuilder}

  setup do
    user =
      user_with_memberships(%{email: "recipe-#{Ecto.UUID.generate()}@example.com"}, [
        {%{plan: :family_4, name: "Recipe household"}, :owner}
      ])

    membership = hd(user.memberships)
    account = Repo.get!(Account, membership.account_id)

    Repo.update!(
      Ecto.Changeset.change(account,
        trial_started_at: DateTime.add(DateTime.utc_now(), -60),
        trial_ends_at: DateTime.add(DateTime.utc_now(), 3600)
      )
    )

    actor = %{id: user.id, account_id: account.id}

    {:ok, ingredient} =
      Catalog.create_ingredient(%{
        name: "Ingredient #{Ecto.UUID.generate()}",
        category: :verduras
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account.id,
        name: "Original soup",
        source: :user_created,
        servings: 2,
        calories_per_serving: 100,
        suitable_for_slots: ["dinner"]
      })

    {:ok, _} =
      Catalog.add_recipe_step(%{
        recipe_id: recipe.id,
        step_number: 1,
        instructions: "Simmer gently"
      })

    {:ok, _} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: ingredient.id,
        quantity_milli: 200,
        unit: :g
      })

    %{actor: actor, recipe: recipe, account: account, user: user, membership: membership}
  end

  test "successor corrections preserve confirmed detail, cooking and shopping", f do
    {:ok, meal} =
      Planning.schedule_meal(%{
        account_id: f.account.id,
        recipe_id: f.recipe.id,
        date: Date.utc_today(),
        slot: :dinner
      })

    {:ok, successor} =
      RecipeVersions.correct(f.recipe.id, %{name: "Corrected soup", calories_per_serving: 250})

    assert successor.recipe_id != f.recipe.id
    assert successor.number == 2
    assert {:ok, original} = RecipeService.get_recipe(f.actor, f.recipe.id)
    assert original.name == "Original soup"
    assert original.version == 1
    assert {:ok, current} = RecipeService.get_recipe(f.actor, successor.recipe_id)
    assert current.name == "Corrected soup"
    assert {:ok, session} = CookingService.start_session(f.actor, meal.id)
    assert session.recipe.name == "Original soup"
    assert hd(session.recipe.steps).instructions == "Simmer gently"

    assert [%{quantity_milli: 200}] =
             ShoppingRebuilder.compute_net_shortages([Repo.reload!(meal)], %{})

    overview =
      MealPlannerApi.Persistence.Calendar.monthly_overview(
        f.account.id,
        f.user.id,
        Date.utc_today(),
        Date.utc_today()
      )

    assert hd(overview.meals).calories_per_serving == 100
  end

  test "expired Accounts cannot read recipe detail", f do
    Repo.update!(
      Ecto.Changeset.change(Repo.reload!(f.account),
        trial_ends_at: DateTime.add(DateTime.utc_now(), -1)
      )
    )

    assert {:error, :subscription_required} = RecipeService.get_recipe(f.actor, f.recipe.id)
  end

  test "detail route enforces active Account scope and subscription even without the rollout flag",
       f do
    token = issue_access_v2_token(f.user, f.membership)

    request = fn id ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/recipes/#{id}")
    end

    assert json_response(request.(f.recipe.id), 200)["data"]["version"] == 1

    other =
      user_with_memberships(%{email: "other-#{Ecto.UUID.generate()}@example.com"}, [
        {%{plan: :individual, name: "Other household"}, :owner}
      ])

    {:ok, foreign} =
      Catalog.create_recipe(%{
        account_id: hd(other.memberships).account_id,
        name: "Foreign",
        source: :user_created
      })

    assert json_response(request.(foreign.id), 404)["error"] == "not_found"
    expire(f.account)
    assert json_response(request.(f.recipe.id), 403)["error"] == "subscription_required"
  end

  test "questions and answers leave no durable transcript or recoverable history", f do
    meal = meal!(f)
    {:ok, session} = CookingService.start_session(f.actor, meal.id)
    assert {:ok, _} = CookingService.answer_question(f.actor, session.session_id, "How hot?")
    assert Repo.aggregate(MealPlannerApi.Persistence.Planning.CookingChatMessage, :count) == 0
    assert {:ok, %{chat_messages: []}} = CookingService.session_state(f.actor, session.session_id)
    assert {:ok, _} = CookingService.finish_session(f.actor, session.session_id)

    assert {:error, :session_closed} =
             CookingService.answer_question(f.actor, session.session_id, "Continue?")

    assert Repo.aggregate(MealPlannerApi.Persistence.Planning.CookingChatMessage, :count) == 0
  end

  test "AI reply is discarded when Account expires while the provider is running", f do
    {:ok, session} = CookingService.start_session(f.actor, meal!(f).id)
    previous = Application.get_env(:meal_planner_api, :ai_client)
    Application.put_env(:meal_planner_api, :ai_client, MealPlannerApi.CookingBarrierClient)
    Application.put_env(:meal_planner_api, :cooking_test_owner, self())

    on_exit(fn ->
      Application.put_env(:meal_planner_api, :ai_client, previous)
      Application.delete_env(:meal_planner_api, :cooking_test_owner)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        CookingService.answer_question(f.actor, session.session_id, "How hot?")
      end)

    assert_receive {:cooking_ai, worker, "How hot?", opts}
    assert opts[:system_prompt] =~ "Simmer gently"
    expire(f.account)
    send(worker, :answer)
    assert {:error, :subscription_required} = Task.await(task)
    assert Repo.aggregate(MealPlannerApi.Persistence.Planning.CookingChatMessage, :count) == 0
  end

  test "published proposals retain their recipe version until recalculation", f do
    {:ok, run} =
      Planning.create_generation_run(%{
        account_id: f.account.id,
        user_id: f.user.id,
        status: :completed,
        input_context: %{},
        started_at: DateTime.utc_now()
      })

    {:ok, proposal} =
      Planning.create_proposal(%{
        generation_run_id: run.id,
        proposal_json: %{slots: [%{slot_key: "2026-10-06_dinner", recipe_id: f.recipe.id}]}
      })

    {:ok, successor} = RecipeVersions.correct(f.recipe.id, %{name: "Successor"})

    assert Repo.reload!(proposal).proposal_json["slots"] |> hd() |> Map.fetch!("recipe_id") ==
             f.recipe.id

    candidates =
      MealPlannerApi.Data.PlanningRepo.candidate_recipe_ids_for_slots(f.account.id, [f.user.id], [
        "dinner"
      ])

    refute f.recipe.id in candidates
    assert successor.recipe_id in candidates
    meal = meal!(f)
    assert meal.recipe_snapshot["name"] == "Original soup"

    assert {:error, :already_superseded} =
             RecipeVersions.correct(f.recipe.id, %{name: "Another correction"})
  end

  test "delayed answers are discarded when the cooking session closes", f do
    {:ok, session} = CookingService.start_session(f.actor, meal!(f).id)
    previous = Application.get_env(:meal_planner_api, :ai_client)
    Application.put_env(:meal_planner_api, :ai_client, MealPlannerApi.CookingBarrierClient)
    Application.put_env(:meal_planner_api, :cooking_test_owner, self())

    on_exit(fn ->
      Application.put_env(:meal_planner_api, :ai_client, previous)
      Application.delete_env(:meal_planner_api, :cooking_test_owner)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        CookingService.answer_question(f.actor, session.session_id, "How hot?")
      end)

    assert_receive {:cooking_ai, worker, "How hot?", _opts}
    assert {:ok, _} = CookingService.finish_session(f.actor, session.session_id)
    send(worker, :answer)
    assert {:error, :session_closed} = Task.await(task)
    assert Repo.aggregate(MealPlannerApi.Persistence.Planning.CookingChatMessage, :count) == 0
  end

  test "revoked membership blocks commands for an existing session", f do
    {:ok, session} = CookingService.start_session(f.actor, meal!(f).id)
    Repo.delete!(f.membership)

    assert {:error, :subscription_required} = RecipeService.get_recipe(f.actor, f.recipe.id)

    assert {:error, :subscription_required} =
             CookingService.session_state(f.actor, session.session_id)

    assert {:error, :subscription_required} =
             CookingService.answer_question(f.actor, session.session_id, "Help")

    assert {:error, :subscription_required} =
             CookingService.finish_session(f.actor, session.session_id)
  end

  test "an audit write failure rolls back cooking completion and inventory", f do
    meal = meal!(f)
    ingredient_id = hd(meal.recipe_snapshot["recipe_ingredients"])["ingredient_id"]

    lot =
      %MealPlannerApi.Persistence.Inventory.InventoryItem{}
      |> MealPlannerApi.Persistence.Inventory.InventoryItem.changeset(%{
        account_id: f.account.id,
        ingredient_id: ingredient_id,
        quantity_milli: 1000,
        unit: :g,
        source_kind: :planned,
        last_mutation_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, session} = CookingService.start_session(f.actor, meal.id)

    Repo.query!("""
    CREATE FUNCTION reject_lifecycle_audit() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      NEW.source_user_id := '00000000-0000-0000-0000-000000000000'::uuid;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER reject_lifecycle_audit BEFORE INSERT ON inventory_mutation_events FOR EACH ROW EXECUTE FUNCTION reject_lifecycle_audit()"
    )

    assert {:error, :inventory_mutation_failed} =
             CookingService.finish_session(f.actor, session.session_id)

    assert Repo.reload!(lot).quantity_milli == 1000
    refute Repo.reload!(meal).is_cooked

    assert Repo.get!(MealPlannerApi.Persistence.Planning.CookingSession, session.session_id).status ==
             :active

    assert Repo.aggregate(MealPlannerApi.Persistence.Inventory.InventoryMutationEvent, :count) ==
             0
  end

  test "confirmed snapshots survive legacy catalog edits and scale selected quantity", f do
    meal = meal!(f, %{selected_quantity: 2})
    Repo.update!(Ecto.Changeset.change(f.recipe, name: "Legacy edit", calories_per_serving: 999))
    assert [%{quantity_milli: 400}] = ShoppingRebuilder.compute_net_shortages([meal], %{})

    slot =
      MealPlannerApi.Persistence.Calendar.get_slot_meal(
        f.account.id,
        f.user.id,
        meal.date,
        :dinner
      )

    assert slot.recipe_name == "Original soup"
    assert slot.calories_per_serving == 100
    assert {:ok, session} = CookingService.start_session(f.actor, meal.id)
    assert hd(session.recipe.ingredients).quantity_milli == 400
    assert {:ok, detail} = RecipeService.get_recipe(f.actor, f.recipe.id)
    assert detail.name == "Original soup"
  end

  test "finishing an old version deducts its selected quantity exactly once after correction",
       f do
    meal = meal!(f, %{selected_quantity: 2})
    ingredient_id = hd(meal.recipe_snapshot["recipe_ingredients"])["ingredient_id"]

    lot =
      %MealPlannerApi.Persistence.Inventory.InventoryItem{}
      |> MealPlannerApi.Persistence.Inventory.InventoryItem.changeset(%{
        account_id: f.account.id,
        ingredient_id: ingredient_id,
        quantity_milli: 1000,
        unit: :g,
        source_kind: :planned,
        last_mutation_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _} =
      RecipeVersions.correct(f.recipe.id, %{
        recipe_ingredients: [%{ingredient_id: ingredient_id, quantity_milli: 500, unit: :g}]
      })

    {:ok, session} = CookingService.start_session(f.actor, meal.id)

    assert {:ok, %{inventory_mutations: 1}} =
             CookingService.finish_session(f.actor, session.session_id)

    assert Repo.reload!(lot).quantity_milli == 600

    assert {:ok, %{inventory_mutations: 0}} =
             CookingService.finish_session(f.actor, session.session_id)

    assert Repo.reload!(lot).quantity_milli == 600
  end

  test "calendar preserves unknown values in a frozen recipe", f do
    Repo.update!(Ecto.Changeset.change(f.recipe, calories_per_serving: nil))
    meal = meal!(f)

    Repo.update!(
      Ecto.Changeset.change(Repo.reload!(f.recipe),
        calories_per_serving: 999,
        prep_time_minutes: 45
      )
    )

    slot =
      MealPlannerApi.Persistence.Calendar.get_slot_meal(
        f.account.id,
        f.user.id,
        meal.date,
        :dinner
      )

    overview =
      MealPlannerApi.Persistence.Calendar.monthly_overview(
        f.account.id,
        f.user.id,
        meal.date,
        meal.date
      )

    assert slot.calories_per_serving == nil
    assert slot.prep_time_minutes == nil
    assert hd(overview.meals).calories_per_serving == nil
    assert hd(overview.meals).prep_time_minutes == nil
  end

  test "bulk calendar insertion freezes snapshots and future inventory reservations use them",
       f do
    tomorrow = Date.add(Date.utc_today(), 1)

    assert {:ok, %{replaced: 1}} =
             MealPlannerApi.Persistence.Calendar.replace_scheduled_meals_for_range(
               f.account.id,
               {tomorrow, tomorrow},
               [%{date: tomorrow, slot: :dinner, recipe_id: f.recipe.id, selected_quantity: 2}]
             )

    [meal] =
      MealPlannerApi.Data.PlanningRepo.list_scheduled_meals(f.account.id, tomorrow, tomorrow)

    assert meal.recipe_version_id
    assert meal.recipe_snapshot["selected_quantity"] == 2
    ingredient_id = hd(meal.recipe_snapshot["recipe_ingredients"])["ingredient_id"]

    %MealPlannerApi.Persistence.Inventory.InventoryItem{}
    |> MealPlannerApi.Persistence.Inventory.InventoryItem.changeset(%{
      account_id: f.account.id,
      ingredient_id: ingredient_id,
      quantity_milli: 1000,
      unit: :g,
      source_kind: :planned,
      last_mutation_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    {:ok, _} =
      RecipeVersions.correct(f.recipe.id, %{
        recipe_ingredients: [%{ingredient_id: ingredient_id, quantity_milli: 500, unit: :g}]
      })

    assert [%{quantity_milli: 600}] = MealPlannerApi.Inventory.available_for(f.actor)
  end

  test "published version content and confirmed snapshots cannot be overwritten", f do
    meal = meal!(f)
    version_id = Ecto.UUID.dump!(meal.recipe_version_id)

    assert_raise Postgrex.Error, ~r/recipe versions are immutable/, fn ->
      Repo.transaction(
        fn ->
          Repo.query!("UPDATE recipe_versions SET snapshot = '{}'::jsonb WHERE id = $1", [
            version_id
          ])
        end,
        mode: :savepoint
      )
    end

    meal_id = Ecto.UUID.dump!(meal.id)

    assert_raise Postgrex.Error, ~r/confirmed recipe snapshot is immutable/, fn ->
      Repo.transaction(
        fn ->
          Repo.query!("UPDATE scheduled_meals SET recipe_snapshot = '{}'::jsonb WHERE id = $1", [
            meal_id
          ])
        end,
        mode: :savepoint
      )
    end

    assert Repo.reload!(meal).recipe_snapshot["name"] == "Original soup"
  end

  defp meal!(f, attrs \\ %{}) do
    {:ok, meal} =
      Planning.schedule_meal(
        Map.merge(
          %{
            account_id: f.account.id,
            recipe_id: f.recipe.id,
            date: Date.utc_today(),
            slot: :dinner
          },
          attrs
        )
      )

    meal
  end

  test "published versions cannot be deleted and republished", f do
    version = RecipeVersions.freeze(f.recipe.id)

    assert_raise Postgrex.Error, ~r/recipe versions are immutable/, fn ->
      Repo.transaction(fn -> Repo.delete!(version) end, mode: :savepoint)
    end

    assert RecipeVersions.freeze(f.recipe.id).id == version.id
  end

  test "confirmed meals cannot be transferred to another Account", f do
    meal = meal!(f)

    other =
      user_with_memberships(%{email: "transfer-#{Ecto.UUID.generate()}@example.com"}, [
        {%{plan: :individual, name: "Other account"}, :owner}
      ])

    assert_raise Postgrex.Error, ~r/confirmed meal Account is immutable/, fn ->
      Repo.transaction(
        fn ->
          Repo.update!(Ecto.Changeset.change(meal, account_id: hd(other.memberships).account_id))
        end,
        mode: :savepoint
      )
    end
  end

  test "empty calendar slots do not permit cooking chat", f do
    {:ok, empty} =
      Planning.schedule_meal(%{account_id: f.account.id, date: Date.utc_today(), slot: :lunch})

    assert {:error, :scheduled_meal_not_found} = CookingService.start_session(f.actor, empty.id)

    {:ok, session} =
      Planning.create_cooking_session(%{
        account_id: f.account.id,
        scheduled_meal_id: empty.id,
        status: :active
      })

    assert {:error, :scheduled_meal_not_found} =
             CookingService.answer_question(f.actor, session.id, "Help me cook")

    assert {:error, :scheduled_meal_not_found} =
             CookingService.finish_session(f.actor, session.id)

    assert Repo.reload!(session).status == :active
    refute Repo.reload!(empty).is_cooked
  end

  test "legacy cooking entry point checks live access", f do
    meal = meal!(f)
    expire(f.account)

    assert {:error, :subscription_required} =
             MealPlannerApi.Services.PlanningService.start_cooking_session(
               f.account.id,
               f.user.id,
               meal.id
             )
  end

  test "cooking cannot use a foreign planned meal through a mismatched session", f do
    other =
      user_with_memberships(%{email: "foreign-session-#{Ecto.UUID.generate()}@example.com"}, [
        {%{plan: :individual, name: "Foreign household"}, :owner}
      ])

    other_account_id = hd(other.memberships).account_id

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: other_account_id,
        name: "Private dish",
        source: :user_created
      })

    {:ok, meal} =
      Planning.schedule_meal(%{
        account_id: other_account_id,
        recipe_id: recipe.id,
        date: Date.utc_today(),
        slot: :dinner
      })

    assert {:error, :scheduled_meal_not_found} = CookingService.start_session(f.actor, meal.id)

    {:ok, session} =
      Planning.create_cooking_session(%{
        account_id: f.account.id,
        scheduled_meal_id: meal.id,
        status: :active
      })

    assert {:error, :scheduled_meal_not_found} = CookingService.session_state(f.actor, session.id)

    assert {:error, :scheduled_meal_not_found} =
             CookingService.answer_question(f.actor, session.id, "Reveal recipe")
  end

  defp expire(account) do
    Repo.update!(
      Ecto.Changeset.change(Repo.reload!(account),
        trial_ends_at: DateTime.add(DateTime.utc_now(), -1)
      )
    )
  end
end
