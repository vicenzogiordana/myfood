defmodule MealPlannerApi.InventoryConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Inventory, as: InventoryPersistence
  alias MealPlannerApi.Persistence.Inventory.{InventoryItem, InventoryMutationEvent}
  alias MealPlannerApi.Repo

  @moduletag :runtime_db_concurrency
  @database_prefix "meal_planner_api_t1_verify_"
  @index_name "inventory_items_positive_stock_lot_lookup_index"
  @composite_index_name "inventory_items_account_id_ingredient_id_unit_source_kind_index"
  @migration_version 20_260_903_000_000
  @migration_module MealPlannerApi.Repo.Migrations.AddPositiveStockLotLookupIndex

  setup_all do
    database = Repo.config()[:database] || ""

    if String.starts_with?(database, @database_prefix) do
      Sandbox.mode(Repo, :auto)
      :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

      Code.require_file(
        Path.expand(
          "../../priv/repo/migrations/20260903000000_add_unique_index_to_inventory_items.exs",
          __DIR__
        )
      )

      on_exit(fn -> Sandbox.mode(Repo, :manual) end)
      {:ok, database: database}
    else
      {:skip,
       "real-connection inventory tests require an explicitly disposable #{@database_prefix}* database"}
    end
  end

  setup do
    fixture = committed_fixture()
    on_exit(fn -> clean_fixture(fixture) end)
    {:ok, fixture}
  end

  test "independent committed transactions serialize anonymous-lot additions without a lost update",
       fixture do
    parent = self()

    workers =
      for delta <- [125, 275] do
        Task.async(fn ->
          Repo.transaction(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("SELECT pg_backend_pid()")
            send(parent, {:transaction_ready, self(), backend_pid})

            receive do
              {:apply_delta, ^parent} -> :ok
            after
              5_000 -> Repo.rollback(:barrier_timeout)
            end

            InventoryPersistence.apply_delta_and_log(%{
              account_id: fixture.account.id,
              ingredient_id: fixture.ingredient.id,
              unit: :g,
              source_kind: :planned,
              delta: delta,
              source_user_id: fixture.user_id,
              trigger_type: :manual,
              operation: :add
            })
          end)
        end)
      end

    ready =
      for _ <- workers do
        assert_receive {:transaction_ready, worker_pid, backend_pid}, 5_000
        {worker_pid, backend_pid}
      end

    assert ready |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 2

    Enum.each(ready, fn {worker_pid, _backend_pid} -> send(worker_pid, {:apply_delta, parent}) end)

    assert Enum.all?(Enum.map(workers, &Task.await(&1, 10_000)), fn
             {:ok, {:ok, %{delta: delta}}} when delta in [125, 275] -> true
             _other -> false
           end)

    [lot] = InventoryPersistence.list_inventory(fixture.account.id)
    assert lot.quantity_milli == 400

    events =
      Repo.all(
        from(e in InventoryMutationEvent,
          where: e.inventory_item_id == ^lot.id,
          order_by: [asc: e.quantity_before_milli]
        )
      )

    assert length(events) == 2

    assert Enum.map(events, &{&1.quantity_before_milli, &1.quantity_after_milli}) ==
             [{0, 125}, {125, 400}] or
             Enum.map(events, &{&1.quantity_before_milli, &1.quantity_after_milli}) ==
               [{0, 275}, {275, 400}]

    Enum.each(events, fn event ->
      assert event.quantity_before_milli + event.quantity_delta_milli ==
               event.quantity_after_milli
    end)
  end

  test "actual lot lookup migration preserves complete duplicate lots and their events",
       fixture do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    lots = [
      insert_lot!(fixture, captured_at, %{quantity_milli: 100}),
      insert_lot!(fixture, captured_at, %{quantity_milli: 200, acquired_price_cents: 22}),
      insert_lot!(fixture, captured_at, %{
        quantity_milli: 300,
        acquired_price_cents: 33,
        acquired_at: DateTime.add(captured_at, -20 * 86_400)
      }),
      insert_lot!(fixture, captured_at, %{
        quantity_milli: 400,
        acquired_price_cents: 44,
        acquired_at: DateTime.add(captured_at, -30 * 86_400),
        expired_at: DateTime.add(captured_at, 2 * 86_400)
      })
    ]

    Enum.with_index(lots, 1)
    |> Enum.each(fn {lot, index} ->
      {:ok, _event} =
        InventoryPersistence.append_inventory_mutation(%{
          account_id: fixture.account.id,
          inventory_item_id: lot.id,
          trigger_type: :manual,
          operation: :add,
          quantity_before_milli: 0,
          quantity_delta_milli: lot.quantity_milli,
          quantity_after_milli: lot.quantity_milli,
          source_user_id: fixture.user_id,
          raw_voice_text: "migration proof #{index}",
          metadata: %{"fixture" => index}
        })
    end)

    snapshot = inventory_snapshot(fixture.account.id)
    indexes_before = inventory_index_definitions()

    assert Map.has_key?(indexes_before, @index_name)
    assert Map.has_key?(indexes_before, @composite_index_name)
    assert_lot_lookup_index_definition()

    # The migrator needs independent connections, not Sandbox ownership.
    migration_repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: fixture.database,
         pool: DBConnection.ConnectionPool,
         pool_size: 2,
         timeout: 10_000,
         parameters: [lock_timeout: "5000", statement_timeout: "10000"]},
        id: :inventory_migration_repo
      )

    assert %{rows: [[database]]} =
             Ecto.Adapters.SQL.query!(migration_repo, "SELECT current_database()", [])

    assert database == fixture.database
    migration_opts = [log: false, dynamic_repo: migration_repo]

    try do
      assert :ok = Ecto.Migrator.down(Repo, @migration_version, @migration_module, migration_opts)
      assert inventory_snapshot(fixture.account.id) == snapshot

      indexes_down = inventory_index_definitions()
      refute Map.has_key?(indexes_down, @index_name)
      assert Map.has_key?(indexes_down, @composite_index_name)
      assert indexes_down == Map.delete(indexes_before, @index_name)

      assert :ok = Ecto.Migrator.up(Repo, @migration_version, @migration_module, migration_opts)
      assert inventory_snapshot(fixture.account.id) == snapshot
      assert inventory_index_definitions() == indexes_before
      assert_lot_lookup_index_definition()
    after
      restore_lot_lookup_migration!(migration_opts)
    end
  end

  defp insert_lot!(fixture, captured_at, attrs) do
    base_attrs = %{
      account_id: fixture.account.id,
      ingredient_id: fixture.ingredient.id,
      quantity_milli: 1,
      unit: :g,
      source_kind: :planned,
      acquired_price_cents: nil,
      acquired_at: nil,
      expired_at: nil,
      last_mutation_at: captured_at
    }

    %InventoryItem{}
    |> InventoryItem.changeset(Map.merge(base_attrs, attrs))
    |> Repo.insert!()
  end

  defp inventory_snapshot(account_id) do
    item_fields = InventoryItem.__schema__(:fields)
    event_fields = InventoryMutationEvent.__schema__(:fields)

    items =
      Repo.all(
        from(i in InventoryItem,
          where: i.account_id == ^account_id,
          order_by: [asc: i.id]
        )
      )

    events =
      Repo.all(
        from(e in InventoryMutationEvent,
          where: e.account_id == ^account_id,
          order_by: [asc: e.id]
        )
      )

    %{
      items: Enum.map(items, &Map.take(&1, item_fields)),
      events: Enum.map(events, &Map.take(&1, event_fields))
    }
  end

  defp inventory_index_definitions do
    %{rows: rows} =
      Repo.query!("""
      SELECT indexname, indexdef
      FROM pg_indexes
      WHERE schemaname = current_schema() AND tablename = 'inventory_items'
      ORDER BY indexname
      """)

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp assert_lot_lookup_index_definition do
    assert %{rows: [[false, predicate, definition]]} =
             Repo.query!(
               """
               SELECT i.indisunique, pg_get_expr(i.indpred, i.indrelid), pg_get_indexdef(i.indexrelid)
               FROM pg_index AS i
               JOIN pg_class AS c ON c.oid = i.indexrelid
               WHERE c.relname = $1
               """,
               [@index_name]
             )

    assert predicate in ["(quantity_milli > 0)", "quantity_milli > 0"]

    assert definition =~
             "(account_id, ingredient_id, unit, source_kind, expired_at)"
  end

  defp restore_lot_lookup_migration!(opts) do
    case Ecto.Migrator.up(Repo, @migration_version, @migration_module, opts) do
      result when result in [:ok, :already_up] -> :ok
    end
  end

  defp committed_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "u_t1_runtime_#{suffix}",
        "account_id" => "acct_t1_runtime_#{suffix}",
        "account_type" => "group",
        "subscription_tier" => "premium"
      })

    {:ok, %{user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: user.id,
        account_id: account.id,
        plan: :family_4
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "T1 runtime ingredient #{suffix}",
        category: :otros
      })

    %{account: account, user: user, user_id: user_id, ingredient: ingredient}
  end

  defp clean_fixture(fixture) do
    Repo.delete_all(from(e in InventoryMutationEvent, where: e.account_id == ^fixture.account.id))

    Repo.delete_all(from(i in InventoryItem, where: i.account_id == ^fixture.account.id))

    Repo.delete_all(
      from(m in MealPlannerApi.Persistence.Accounts.AccountMembership,
        where: m.account_id == ^fixture.account.id
      )
    )

    Repo.delete_all(
      from(a in MealPlannerApi.Persistence.Accounts.Account, where: a.id == ^fixture.account.id)
    )

    Repo.delete_all(
      from(i in MealPlannerApi.Persistence.Catalog.Ingredient,
        where: i.id == ^fixture.ingredient.id
      )
    )

    Repo.delete_all(
      from(u in MealPlannerApi.Persistence.Accounts.User, where: u.id == ^fixture.user.id)
    )
  end
end
