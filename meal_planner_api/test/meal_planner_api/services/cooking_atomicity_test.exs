defmodule MealPlannerApi.Services.CookingAtomicityTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Inventory.{InventoryItem, InventoryMutationEvent}
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Persistence.Planning.{CookingSession, ScheduledMeal}
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.CookingService

  @moduletag :runtime_db_concurrency
  @isolated_database "meal_planner_api_t1_verify_20261005_t1"
  if System.get_env("MYFOOD_TEST_DATABASE") != @isolated_database do
    @moduletag skip: "requires the explicitly isolated T1 verification database"
  end

  setup_all do
    assert Repo.config()[:database] == @isolated_database

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: @isolated_database,
         pool: DBConnection.ConnectionPool,
         pool_size: 4,
         timeout: 10_000,
         parameters: [lock_timeout: "3000", statement_timeout: "8000"]}
      )

    assert %{rows: [[@isolated_database]]} =
             Ecto.Adapters.SQL.query!(repo, "SELECT current_database()", [])

    {:ok, repo: repo}
  end

  setup %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    fixture = fixture()

    on_exit(fn ->
      Repo.put_dynamic_repo(repo)
      cleanup(fixture)
    end)

    {:ok, fixture}
  end

  test "completion consumes FEFO lots once, audits the actor, and excludes expired and extra stock",
       f do
    first = hd(f.ingredients)
    later = hd(f.lots)
    now = DateTime.utc_now()
    early = lot!(f, first, %{quantity_milli: 100, expired_at: DateTime.add(now, 86_400)})
    expired = lot!(f, first, %{expired_at: DateTime.add(now, -86_400)})
    extra = lot!(f, first, %{source_kind: :extra})

    assert {:ok, %{inventory_mutations: 2}} = finish(f)
    assert Repo.get!(InventoryItem, early.id).quantity_milli == 0
    assert Repo.get!(InventoryItem, later.id).quantity_milli == 900
    assert Repo.get!(InventoryItem, expired.id).quantity_milli == 1000
    assert Repo.get!(InventoryItem, extra.id).quantity_milli == 1000
    assert Repo.get!(ScheduledMeal, f.meal.id).is_cooked
    completed = Repo.get!(CookingSession, f.session.id)
    assert completed.status == :completed
    assert completed.completed_at

    events = events(f)
    assert length(events) == 3
    assert Enum.sum(Enum.map(events, & &1.quantity_delta_milli)) == -400

    for event <- events do
      assert event.account_id == f.account.id
      assert event.source_user_id == f.user.id
      assert event.source_cooking_session_id == f.session.id
      assert event.trigger_type == :cooking

      assert event.quantity_before_milli + event.quantity_delta_milli ==
               event.quantity_after_milli
    end

    assert {:ok, %{inventory_mutations: 0}} = finish(f)
    assert events(f) == events
    assert Repo.get!(CookingSession, f.session.id) == completed
  end

  test "another account cannot finish the session or consume its stock", f do
    foreign = fixture()

    try do
      assert {:error, :session_not_found} =
               CookingService.finish_session(foreign.actor, f.session.id)

      assert_unchanged(f)
      assert_unchanged(foreign)
    after
      cleanup(foreign)
    end
  end

  for {table, field} <- [
        {"inventory_mutation_events", "source_user_id"},
        {"scheduled_meals", "account_id"},
        {"cooking_sessions", "account_id"}
      ] do
    test "failure writing #{table} rolls back session, meal, all lots and audit events", f do
      table = unquote(table)
      field = unquote(field)
      last_lot = List.last(f.lots)

      condition =
        if table == "inventory_mutation_events",
          do: "NEW.inventory_item_id = '#{last_lot.id}'::uuid",
          else:
            "NEW.id = '#{if table == "scheduled_meals", do: f.meal.id, else: f.session.id}'::uuid"

      # Fail a declared FK through the real persistence seam, after earlier deductions.
      # Both DDL objects are removed even if a behavioral assertion fails.
      Repo.query!("""
      CREATE FUNCTION cooking_atomicity_failure() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF #{condition} THEN
          IF NOT EXISTS (SELECT 1 FROM inventory_mutation_events
                         WHERE source_cooking_session_id = '#{f.session.id}'::uuid) THEN
            RAISE EXCEPTION 'failure injection must follow an earlier audit write';
          END IF;
          NEW.#{field} := '00000000-0000-0000-0000-000000000000'::uuid;
        END IF;
        RETURN NEW;
      END $$
      """)

      try do
        Repo.query!("""
        CREATE TRIGGER cooking_atomicity_failure BEFORE INSERT OR UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION cooking_atomicity_failure()
        """)

        assert {:error, _reason} = finish(f)
        assert_unchanged(f)
      after
        Repo.query!("DROP TRIGGER IF EXISTS cooking_atomicity_failure ON #{table}")
        Repo.query!("DROP FUNCTION cooking_atomicity_failure()")
      end

      assert {:ok, %{inventory_mutations: 2}} = finish(f)
      assert length(events(f)) == 2
    end
  end

  for separate_session? <- [false, true] do
    test "concurrent completion deducts once with separate_session=#{separate_session?}", f do
      other =
        if unquote(separate_session?), do: session!(f.account.id, f.meal.id), else: f.session

      results = concurrent_finish(f, [f.session.id, other.id])
      assert Enum.sort(Enum.map(results, & &1.inventory_mutations)) == [0, 2]
      assert length(events(f)) == 2
      assert Enum.all?(f.lots, &(Repo.get!(InventoryItem, &1.id).quantity_milli == 800))
      assert Repo.get!(CookingSession, f.session.id).status == :completed
      assert Repo.get!(CookingSession, other.id).status == :completed
      assert Repo.get!(ScheduledMeal, f.meal.id).is_cooked
    end
  end

  test "distinct meals sharing ingredients serialize their deductions without losing stock", f do
    {:ok, meal} =
      Planning.schedule_meal(%{
        account_id: f.account.id,
        recipe_id: f.recipe.id,
        date: Date.add(Date.utc_today(), 1),
        slot: :dinner
      })

    other = session!(f.account.id, meal.id)
    results = concurrent_finish(f, [f.session.id, other.id])
    assert Enum.map(results, & &1.inventory_mutations) == [2, 2]
    assert length(events(f)) == 4
    assert Enum.all?(f.lots, &(Repo.get!(InventoryItem, &1.id).quantity_milli == 600))
  end

  defp concurrent_finish(f, session_ids) do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    workers =
      Enum.map(session_ids, fn session_id ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          Repo.put_dynamic_repo(f.repo)

          Repo.transaction(fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), pid})

            receive do
              :finish ->
                result = CookingService.finish_session(f.actor, session_id)

                if match?({:ok, %{inventory_mutations: 2}}, result) do
                  assert %{rows: [[2]]} =
                           Repo.query!("""
                           SELECT count(*) FROM pg_locks
                           WHERE pid = pg_backend_pid() AND locktype = 'advisory' AND granted
                           """)
                end

                result
            after
              5_000 -> Repo.rollback(:barrier_timeout)
            end
          end)
        end)
      end)

    ready =
      for _ <- workers do
        assert_receive {:ready, worker, pid}, 5_000
        {worker, pid}
      end

    assert length(Enum.uniq(Enum.map(ready, &elem(&1, 1)))) == 2
    Enum.each(ready, fn {worker, _pid} -> send(worker, :finish) end)

    Enum.map(workers, fn worker ->
      assert {:ok, {:ok, result}} = Task.await(worker, 12_000)
      result
    end)
  end

  defp finish(f), do: CookingService.finish_session(f.actor, f.session.id)

  defp events(f) do
    Repo.all(
      from(e in InventoryMutationEvent, where: e.account_id == ^f.account.id, order_by: e.id)
    )
  end

  defp assert_unchanged(f) do
    assert Repo.get!(CookingSession, f.session.id) == f.session
    assert Repo.get!(ScheduledMeal, f.meal.id) == f.meal
    for lot <- f.lots, do: assert(Repo.get!(InventoryItem, lot.id) == lot)
    assert events(f) == []
  end

  defp fixture do
    {:ok, fixture} = Repo.transaction(&build_fixture/0)
    fixture
  end

  defp build_fixture do
    suffix = Ecto.UUID.generate()

    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "cook_atomic_#{suffix}",
        "account_id" => "cook_atomic_#{suffix}",
        "account_type" => "group",
        "subscription_tier" => "premium"
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Atomic cooking #{suffix}",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:dinner]
      })

    ingredients =
      for n <- 1..2 do
        {:ok, ingredient} =
          Catalog.upsert_ingredient_by_name(%{name: "Atomic #{suffix} #{n}", category: :otros})

        ingredient
      end
      |> Enum.sort_by(& &1.id)

    # Deliberately insert in reverse logical-key order.
    for ingredient <- Enum.reverse(ingredients) do
      {:ok, _} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: 200,
          unit: :g
        })
    end

    {:ok, meal} =
      Planning.schedule_meal(%{
        account_id: account.id,
        recipe_id: recipe.id,
        date: Date.utc_today(),
        slot: :dinner
      })

    f = %{
      user: user,
      account: account,
      recipe: recipe,
      ingredients: ingredients,
      meal: meal,
      session: session!(account.id, meal.id),
      actor: %{id: user.id, account_id: account.id, plan: :family_4}
    }

    Map.put(f, :lots, Enum.map(ingredients, &lot!(f, &1, %{})))
  end

  defp session!(account_id, meal_id) do
    {:ok, session} =
      Planning.create_cooking_session(%{
        account_id: account_id,
        scheduled_meal_id: meal_id,
        status: :active
      })

    session
  end

  defp lot!(f, ingredient, attrs) do
    %InventoryItem{}
    |> InventoryItem.changeset(
      Map.merge(
        %{
          account_id: f.account.id,
          ingredient_id: ingredient.id,
          quantity_milli: 1000,
          unit: :g,
          source_kind: :planned,
          last_mutation_at: DateTime.utc_now(),
          expired_at: DateTime.add(DateTime.utc_now(), 5 * 86_400)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp cleanup(f) do
    Repo.delete_all(from(e in InventoryMutationEvent, where: e.account_id == ^f.account.id))
    Repo.delete_all(from(i in InventoryItem, where: i.account_id == ^f.account.id))
    Repo.delete_all(from(m in ScheduledMeal, where: m.account_id == ^f.account.id))
    Repo.delete_all(from(r in Catalog.Recipe, where: r.account_id == ^f.account.id))

    Repo.delete_all(
      from(m in MealPlannerApi.Persistence.Accounts.AccountMembership,
        where: m.account_id == ^f.account.id
      )
    )

    Repo.delete_all(
      from(u in MealPlannerApi.Persistence.Accounts.User, where: u.id == ^f.user.id)
    )

    Repo.delete_all(
      from(a in MealPlannerApi.Persistence.Accounts.Account, where: a.id == ^f.account.id)
    )

    ids = Enum.map(f.ingredients, & &1.id)
    Repo.delete_all(from(i in Catalog.Ingredient, where: i.id in ^ids))
  end
end
