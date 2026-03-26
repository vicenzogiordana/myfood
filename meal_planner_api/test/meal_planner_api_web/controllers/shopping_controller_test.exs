defmodule MealPlannerApiWeb.ShoppingControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Inventory
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Persistence.Shopping

  test "shopping list supports grouping, assignment, cart marking and checkout", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_shop", "account_id" => "acct_shop"})
    start_date = Date.utc_today()
    end_date = Date.add(start_date, 6)
    second_meal_date = Date.add(start_date, 3)

    {:ok, %{account_id: account_id, user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: "u_shop",
        account_id: "acct_shop",
        account_type: :group
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Carne Test Shopping",
        category: :carnes,
        calories_per_100: 250,
        protein_g_per_100: Decimal.new("26.0"),
        carbs_g_per_100: Decimal.new("0.0"),
        fat_g_per_100: Decimal.new("15.0")
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Milanesa y estofado",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:lunch]
      })

    {:ok, _step} =
      Catalog.add_recipe_step(%{
        recipe_id: recipe.id,
        step_number: 1,
        instructions: "Preparar carne",
        duration_minutes: 20
      })

    {:ok, _ri} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: ingredient.id,
        quantity_milli: 500,
        unit: :g
      })

    {:ok, meal_1} =
      Planning.schedule_meal(%{
        account_id: account_id,
        date: start_date,
        slot: :lunch,
        recipe_id: recipe.id,
        is_cooked: false
      })

    {:ok, meal_2} =
      Planning.schedule_meal(%{
        account_id: account_id,
        date: second_meal_date,
        slot: :lunch,
        recipe_id: recipe.id,
        is_cooked: false
      })

    # Manual shopping rows so grouped quantity is deterministic: 500g + 400g = 900g
    {:ok, _item_1} =
      Shopping.create_shopping_item(%{
        account_id: account_id,
        scheduled_meal_id: meal_1.id,
        planned_date: start_date,
        ingredient_id: ingredient.id,
        quantity_milli: 500,
        unit: :g,
        status: :pending,
        estimated_price_cents: 6000
      })

    {:ok, _item_2} =
      Shopping.create_shopping_item(%{
        account_id: account_id,
        scheduled_meal_id: meal_2.id,
        planned_date: second_meal_date,
        ingredient_id: ingredient.id,
        quantity_milli: 400,
        unit: :g,
        status: :pending,
        estimated_price_cents: 4500
      })

    {:ok, supermarket_a} =
      Shopping.upsert_supermarket_by_name(%{
        name: "Coto Test",
        chain: "Coto",
        pricing_scrape_enabled: true
      })

    {:ok, supermarket_b} =
      Shopping.upsert_supermarket_by_name(%{
        name: "Carrefour Test",
        chain: "Carrefour",
        pricing_scrape_enabled: true
      })

    {:ok, _cat_a} =
      Shopping.upsert_supermarket_catalog(%{
        supermarket_id: supermarket_a.id,
        ingredient_id: ingredient.id,
        price_cents_ars: 1000,
        unit: "g",
        price_date: ~D[2026-03-23],
        last_scraped_at: DateTime.utc_now()
      })

    {:ok, _cat_b} =
      Shopping.upsert_supermarket_catalog(%{
        supermarket_id: supermarket_b.id,
        ingredient_id: ingredient.id,
        price_cents_ars: 900,
        unit: "g",
        price_date: ~D[2026-03-23],
        last_scraped_at: DateTime.utc_now()
      })

    list_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/shopping-list", %{
        "start_date" => Date.to_iso8601(start_date),
        "end_date" => Date.to_iso8601(end_date),
        "optimize_prices" => "true"
      })

    list_body = json_response(list_conn, 200)
    grouped_items = list_body["data"]["items"]
    assert length(grouped_items) == 1

    grouped = hd(grouped_items)
    assert grouped["ingredient_id"] == ingredient.id
    assert grouped["total_quantity_milli"] == 900
    assert grouped["category"] == "carnes"
    assert length(grouped["price_options"]) == 2

    mark_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/shopping-items/mark-cart", %{
        "ingredient_id" => ingredient.id,
        "in_cart" => true,
        "start_date" => Date.to_iso8601(start_date),
        "end_date" => Date.to_iso8601(end_date)
      })

    mark_body = json_response(mark_conn, 200)
    assert mark_body["data"]["status"] == "in_cart"
    assert mark_body["data"]["updated_rows"] == 2

    assign_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/shopping-items/assign-supermarket", %{
        "ingredient_id" => ingredient.id,
        "supermarket_id" => supermarket_a.id,
        "start_date" => Date.to_iso8601(start_date),
        "end_date" => Date.to_iso8601(end_date)
      })

    assign_body = json_response(assign_conn, 200)
    assert assign_body["data"]["assigned_supermarket_id"] == supermarket_a.id
    assert assign_body["data"]["updated_rows"] == 2

    checkout_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/checkout/confirm", %{
        "checkout_type" => "physical",
        "start_date" => Date.to_iso8601(start_date),
        "end_date" => Date.to_iso8601(end_date)
      })

    checkout_body = json_response(checkout_conn, 200)
    assert checkout_body["data"]["status"] == "completed"
    assert checkout_body["data"]["checkout_type"] == "physical"
    assert checkout_body["data"]["moved_to_inventory_count"] == 2

    inventory = Inventory.list_inventory(account_id)
    assert length(inventory) == 1
    assert hd(inventory).quantity_milli == 900

    shopping_items = Shopping.list_items_for_account(account_id)
    assert Enum.all?(shopping_items, &(&1.status == :checked_out))
  end

  test "past unpurchased rows are auto-pruned", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_prune", "account_id" => "acct_prune"})

    {:ok, %{account_id: account_id, user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: "u_prune",
        account_id: "acct_prune",
        account_type: :group
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Leche Test Prune",
        category: :lacteos,
        calories_per_100: 60,
        protein_g_per_100: Decimal.new("3.2"),
        carbs_g_per_100: Decimal.new("4.8"),
        fat_g_per_100: Decimal.new("3.3")
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Cafe con leche",
        source: :user_created,
        servings: 1,
        suitable_for_slots: [:breakfast]
      })

    {:ok, _ri} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: ingredient.id,
        quantity_milli: 250,
        unit: :ml
      })

    {:ok, meal} =
      Planning.schedule_meal(%{
        account_id: account_id,
        date: Date.add(Date.utc_today(), -2),
        slot: :breakfast,
        recipe_id: recipe.id,
        is_cooked: false
      })

    {:ok, _item} =
      Shopping.create_shopping_item(%{
        account_id: account_id,
        scheduled_meal_id: meal.id,
        planned_date: Date.add(Date.utc_today(), -2),
        ingredient_id: ingredient.id,
        quantity_milli: 250,
        unit: :ml,
        status: :pending
      })

    _ =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/shopping-list", %{
        "start_date" => Date.to_iso8601(Date.utc_today()),
        "end_date" => Date.to_iso8601(Date.add(Date.utc_today(), 2))
      })

    items = Shopping.list_items_for_account(account_id)
    assert Enum.any?(items, &(&1.status == :archived))
  end

  test "online checkout waits for delivery before inventory mutation", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_online", "account_id" => "acct_online"})
    start_date = Date.utc_today()
    end_date = Date.add(start_date, 6)
    planned_date = Date.add(start_date, 1)

    {:ok, %{account_id: account_id, user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: "u_online",
        account_id: "acct_online",
        account_type: :group
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Arroz Test Online",
        category: :granos,
        calories_per_100: 130,
        protein_g_per_100: Decimal.new("2.7"),
        carbs_g_per_100: Decimal.new("28.0"),
        fat_g_per_100: Decimal.new("0.3")
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Arroz simple",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:dinner]
      })

    {:ok, _ri} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: ingredient.id,
        quantity_milli: 300,
        unit: :g
      })

    {:ok, meal} =
      Planning.schedule_meal(%{
        account_id: account_id,
        date: planned_date,
        slot: :dinner,
        recipe_id: recipe.id,
        is_cooked: false
      })

    {:ok, _item} =
      Shopping.create_shopping_item(%{
        account_id: account_id,
        scheduled_meal_id: meal.id,
        planned_date: planned_date,
        ingredient_id: ingredient.id,
        quantity_milli: 300,
        unit: :g,
        status: :in_cart,
        estimated_price_cents: 2000
      })

    checkout_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/checkout/confirm", %{
        "checkout_type" => "online",
        "start_date" => Date.to_iso8601(start_date),
        "end_date" => Date.to_iso8601(end_date)
      })

    checkout_body = json_response(checkout_conn, 200)
    checkout_session_id = checkout_body["data"]["checkout_session_id"]

    assert checkout_body["data"]["status"] == "pending_delivery"
    assert checkout_body["data"]["moved_to_inventory_count"] == 0

    assert Inventory.list_inventory(account_id) == []

    item_statuses_before = Shopping.list_items_for_account(account_id) |> Enum.map(& &1.status)
    assert Enum.any?(item_statuses_before, &(&1 == :pending_delivery))

    delivered_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/checkout/sessions/#{checkout_session_id}/delivered")

    delivered_body = json_response(delivered_conn, 200)
    assert delivered_body["data"]["status"] == "completed"
    assert delivered_body["data"]["moved_to_inventory_count"] == 1

    inventory = Inventory.list_inventory(account_id)
    assert length(inventory) == 1
    assert hd(inventory).quantity_milli == 300

    item_statuses_after = Shopping.list_items_for_account(account_id) |> Enum.map(& &1.status)
    assert Enum.any?(item_statuses_after, &(&1 == :checked_out))
  end

  defp issue_token(conn, params) do
    response = conn |> post("/api/auth/token", params) |> json_response(200)
    response["access_token"]
  end
end
