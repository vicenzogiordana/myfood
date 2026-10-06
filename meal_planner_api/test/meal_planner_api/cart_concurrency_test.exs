defmodule MealPlannerApi.CartConcurrencyTest do
  use ExUnit.Case, async: false
  import MealPlannerApi.CartFixtures
  alias MealPlannerApi.{Cart, Repo}
  alias MealPlannerApi.Persistence.Shopping.CheckoutSession

  @moduletag :runtime_db_concurrency
  unless MealPlannerApi.Issue38Database.enabled?() do
    @moduletag skip: "requires test/support/issue38_concurrency_runner.exs and a fresh database"
  end

  setup_all do
    database = MealPlannerApi.Issue38Database.database!()

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: database,
         pool: DBConnection.ConnectionPool,
         pool_size: 4,
         timeout: 10_000,
         parameters: [lock_timeout: "3000", statement_timeout: "8000"]}
      )

    assert %{rows: [[^database]]} =
             Ecto.Adapters.SQL.query!(repo, "SELECT current_database()", [])

    {:ok, repo: repo}
  end

  setup %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    f = fixture()

    on_exit(fn ->
      Repo.put_dynamic_repo(repo)
      cleanup(f)
    end)

    {:ok, f}
  end

  test "two independent connections reserving the same lines have exactly one owner", f do
    ids = Enum.map(f.items, & &1.id)

    results =
      concurrent(f, [fn -> Cart.reserve(f.actor, ids) end, fn -> Cart.reserve(f.other, ids) end])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :already_reserved} in results
    [{:ok, cart}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.all?(lines(f), &(&1.checkout_session_id == cart.session_id))
  end

  test "concurrent duplicate purchase commits one set of lots, spend and movements", f do
    cart = reserve!(f)
    Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "shopping:#{f.account.id}")
    purchase = fn -> Cart.purchase(f.actor, cart.session_id, payload(cart)) end
    results = concurrent(f, [purchase, purchase])
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :already_purchased} in results
    assert length(stock(f)) == 2
    assert length(events(f)) == 2
    assert Repo.get!(CheckoutSession, cart.session_id).total_cents == 500
    assert_receive %Phoenix.Socket.Broadcast{event: "purchase_confirmed"}
    assert_receive %Phoenix.Socket.Broadcast{event: "inventory_changed"}
    refute_receive %Phoenix.Socket.Broadcast{event: "purchase_confirmed"}
  end

  test "different members purchasing separate reservations accumulate stock and separate audits",
       f do
    [first, second] = f.items
    {:ok, cart_a} = Cart.reserve(f.actor, [first.id])
    {:ok, cart_b} = Cart.reserve(f.other, [second.id])

    results =
      concurrent(f, [
        fn -> Cart.purchase(f.actor, cart_a.session_id, payload(cart_a)) end,
        fn -> Cart.purchase(f.other, cart_b.session_id, payload(cart_b)) end
      ])

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Enum.sum(Enum.map(stock(f), & &1.quantity_milli)) == 600

    assert Enum.sort(Enum.map(events(f), & &1.source_user_id)) ==
             Enum.sort([f.owner.id, f.member.id])

    assert Repo.get!(CheckoutSession, cart_a.session_id).total_cents == 250
    assert Repo.get!(CheckoutSession, cart_b.session_id).total_cents == 250
  end

  test "cart migration down and up preserve preexisting rows and restore indexes", f do
    # Never drop populated lease metadata, even on the explicitly isolated database.
    assert %{rows: [[0]]} =
             Repo.query!("""
             SELECT count(*) FROM checkout_sessions
             WHERE reserved_by_user_id IS NOT NULL OR lease_expires_at IS NOT NULL OR purchase_result IS NOT NULL
             """)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM shopping_items WHERE reservation_token IS NOT NULL"
             )

    Code.require_file(
      Path.expand("../../priv/repo/migrations/20261005000000_add_cart_leases.exs", __DIR__)
    )

    migration = MealPlannerApi.Repo.Migrations.AddCartLeases
    version = 20_261_005_000_000
    options = [log: false, dynamic_repo: f.repo]
    snapshot = migration_snapshot()
    indexes = cart_indexes()
    assert Enum.any?(indexes, fn [name, _] -> name == "one_active_member_cart" end)

    try do
      assert :ok = Ecto.Migrator.down(Repo, version, migration, options)
      assert migration_snapshot() == snapshot

      refute Enum.any?(cart_indexes(), fn [name, _] ->
               name in ["cart_expiry_lookup", "one_active_member_cart"]
             end)

      assert :ok = Ecto.Migrator.up(Repo, version, migration, options)
      assert migration_snapshot() == snapshot
      assert cart_indexes() == indexes
    after
      assert Ecto.Migrator.up(Repo, version, migration, options) in [:ok, :already_up]
    end
  end

  test "purchase versus cancellation never leaves partial stock or a live reservation", f do
    cart = reserve!(f)

    results =
      concurrent(f, [
        fn -> Cart.purchase(f.actor, cart.session_id, payload(cart)) end,
        fn -> Cart.cancel(f.actor, cart.session_id) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :stale_cart} in results
    status = Repo.get!(CheckoutSession, cart.session_id).status

    if status == :completed do
      assert length(stock(f)) == 2
      assert length(events(f)) == 2
    else
      assert status == :abandoned
      assert stock(f) == []
      assert events(f) == []
      assert Enum.all?(lines(f), &(&1.status == :pending))
    end

    refute Enum.any?(lines(f), &(&1.status == :in_cart))
  end

  test "concurrent expiry sweepers release once and stale confirmation adds nothing", f do
    cart = reserve!(f)
    expire!(cart)
    Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "shopping:#{f.account.id}")

    results =
      concurrent(f, [
        fn -> Cart.expire_account(f.account.id) end,
        fn -> Cart.expire_account(f.account.id) end
      ])

    assert Enum.sort(results) == [{:ok, 0}, {:ok, 1}]
    assert_receive %Phoenix.Socket.Broadcast{event: "cart_expired"}
    refute_receive %Phoenix.Socket.Broadcast{event: "cart_expired"}
    assert {:error, :stale_cart} = Cart.purchase(f.actor, cart.session_id, payload(cart))
    assert stock(f) == []
    assert events(f) == []
  end

  test "a failed release rolls back every line and keeps the original cart lease", f do
    cart = reserve!(f)
    original = {lines(f), Repo.get!(CheckoutSession, cart.session_id)}
    last = List.last(lines(f))
    trigger = "cart_release_failure_" <> String.replace(Ecto.UUID.generate(), "-", "")

    Repo.query!("""
    CREATE FUNCTION #{trigger}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.id = '#{last.id}'::uuid AND NEW.status = 'pending' THEN
        NEW.account_id := '#{Ecto.UUID.generate()}'::uuid;
      END IF;
      RETURN NEW;
    END $$
    """)

    try do
      Repo.query!(
        "CREATE TRIGGER #{trigger} BEFORE UPDATE ON shopping_items FOR EACH ROW EXECUTE FUNCTION #{trigger}()"
      )

      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "shopping:#{f.account.id}")
      assert {:error, %Ecto.Changeset{}} = Cart.cancel(f.actor, cart.session_id)
      assert {lines(f), Repo.get!(CheckoutSession, cart.session_id)} == original
      refute_receive %Phoenix.Socket.Broadcast{event: "cart_released"}

      assert {:error, %Ecto.Changeset{}} =
               Cart.remove(f.actor, cart.session_id, payload(cart)["items"])

      assert {lines(f), Repo.get!(CheckoutSession, cart.session_id)} == original
    after
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON shopping_items")
      Repo.query!("DROP FUNCTION IF EXISTS #{trigger}()")
    end
  end

  for table <- ["inventory_mutation_events", "shopping_items", "checkout_sessions"] do
    test "failure writing #{table} rolls back stock, audit, remainder and spend without a broadcast",
         f do
      table = unquote(table)
      cart = reserve!(f)
      original = {lines(f), Repo.get!(CheckoutSession, cart.session_id)}
      Phoenix.PubSub.subscribe(MealPlannerApi.PubSub, "shopping:#{f.account.id}")
      trigger = "cart_failure_" <> String.replace(Ecto.UUID.generate(), "-", "")

      condition =
        case table do
          "inventory_mutation_events" ->
            "NEW.source_checkout_session_id = '#{cart.session_id}'::uuid"

          "shopping_items" ->
            "NEW.account_id = '#{f.account.id}'::uuid AND NEW.status = 'checked_out'"

          "checkout_sessions" ->
            "NEW.id = '#{cart.session_id}'::uuid AND NEW.status = 'completed'"
        end

      Repo.query!("""
      CREATE FUNCTION #{trigger}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF #{condition} THEN NEW.account_id := '#{Ecto.UUID.generate()}'::uuid; END IF;
        RETURN NEW;
      END $$
      """)

      try do
        Repo.query!(
          "CREATE TRIGGER #{trigger} BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION #{trigger}()"
        )

        assert {:error, %Ecto.Changeset{}} =
                 Cart.purchase(f.actor, cart.session_id, payload(cart))

        assert stock(f) == []
        assert events(f) == []
        assert {lines(f), Repo.get!(CheckoutSession, cart.session_id)} == original
        refute_receive %Phoenix.Socket.Broadcast{event: "purchase_confirmed"}
        refute_receive %Phoenix.Socket.Broadcast{event: "inventory_changed"}
      after
        Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON #{table}")
        Repo.query!("DROP FUNCTION IF EXISTS #{trigger}()")
      end

      assert {:ok, _} = Cart.purchase(f.actor, cart.session_id, payload(cart))
    end
  end

  defp concurrent(f, commands) do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      Enum.map(commands, fn command ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          Repo.put_dynamic_repo(f.repo)

          Repo.checkout(fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), pid})

            receive do
              :go -> command.()
            after
              5000 -> raise "cart concurrency barrier timed out"
            end
          end)
        end)
      end)

    ready =
      for _ <- tasks do
        assert_receive {:ready, worker, pid}, 5000
        {worker, pid}
      end

    assert length(Enum.uniq(Enum.map(ready, &elem(&1, 1)))) == 2
    Enum.each(ready, fn {worker, _} -> send(worker, :go) end)
    Enum.map(tasks, &Task.await(&1, 12_000))
  end

  defp migration_snapshot do
    for table <- [
          "shopping_items",
          "checkout_sessions",
          "inventory_items",
          "inventory_mutation_events"
        ] do
      result =
        Repo.query!("""
        SELECT to_jsonb(t) - 'reserved_by_user_id' - 'lease_expires_at' - 'purchase_result' - 'reservation_token'
        FROM #{table} t ORDER BY id
        """)

      {table, result.rows}
    end
  end

  defp cart_indexes do
    Repo.query!(
      "SELECT indexname, indexdef FROM pg_indexes WHERE tablename IN ('shopping_items', 'checkout_sessions') ORDER BY indexname"
    ).rows
  end
end
