defmodule MealPlannerApiWeb.InventoryControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Inventory
  alias MealPlannerApi.Persistence.Planning

  test "inventory list, manual adjust, dispose and voice flow", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_inv", "account_id" => "acct_inv"})

    {:ok, %{account_id: account_id, user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: "u_inv",
        account_id: "acct_inv",
        account_type: :group
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Pan Test Inventario",
        category: :no_perecederos,
        calories_per_100: 260,
        protein_g_per_100: Decimal.new("8.0"),
        carbs_g_per_100: Decimal.new("49.0"),
        fat_g_per_100: Decimal.new("3.2")
      })

    {:ok, _seed} =
      Inventory.apply_delta_and_log(%{
        account_id: account_id,
        ingredient_id: ingredient.id,
        unit: :g,
        source_kind: :planned,
        delta: 1000,
        source_user_id: user_id,
        trigger_type: :purchase,
        operation: :add
      })

    list_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/inventory")

    list_body = json_response(list_conn, 200)
    assert list_body["data"]["totals"]["items_count"] == 1

    item = hd(list_body["data"]["sections"]["ok"])
    item_id = item["id"]

    adjust_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/inventory/items/#{item_id}/quantity", %{"quantity_milli" => 750})

    adjust_body = json_response(adjust_conn, 200)
    assert adjust_body["data"]["quantity_after_milli"] == 750

    preview_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/inventory/voice/preview", %{"text" => "me comi medio pan test inventario"})

    preview_body = json_response(preview_conn, 200)
    assert preview_body["data"]["confirmation_required"] == true
    assert length(preview_body["data"]["operations"]) >= 1

    apply_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/inventory/voice/apply", %{
        "raw_text" => preview_body["data"]["raw_text"],
        "operations" => preview_body["data"]["operations"]
      })

    apply_body = json_response(apply_conn, 200)
    assert apply_body["data"]["applied_operations"] >= 1

    dispose_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/inventory/items/#{item_id}/dispose", %{"reason" => "spoiled"})

    dispose_body = json_response(dispose_conn, 200)
    assert dispose_body["data"]["item_id"] == item_id
  end

  test "rescue plan schedules meal for today", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_rescue", "account_id" => "acct_rescue"})

    {:ok, %{account_id: account_id, user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: "u_rescue",
        account_id: "acct_rescue",
        account_type: :group
      })

    {:ok, tomato} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Tomate Test Rescue",
        category: :verduras,
        calories_per_100: 18,
        protein_g_per_100: Decimal.new("0.9"),
        carbs_g_per_100: Decimal.new("3.9"),
        fat_g_per_100: Decimal.new("0.2")
      })

    {:ok, dough} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Tapa Tarta Test Rescue",
        category: :granos,
        calories_per_100: 290,
        protein_g_per_100: Decimal.new("6.0"),
        carbs_g_per_100: Decimal.new("45.0"),
        fat_g_per_100: Decimal.new("9.0")
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Tarta de Tomate Rescue",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:dinner]
      })

    {:ok, _ri1} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: tomato.id,
        quantity_milli: 300,
        unit: :g
      })

    {:ok, _ri2} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: dough.id,
        quantity_milli: 1,
        unit: :unit
      })

    rescue_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/planning/rescue", %{
        "ingredient_ids" => [tomato.id, dough.id]
      })

    rescue_body = json_response(rescue_conn, 200)
    assert rescue_body["data"]["status"] == "scheduled"
    assert rescue_body["data"]["recipe"]["id"] == recipe.id

    meals = Planning.list_scheduled_meals(account_id, Date.utc_today(), Date.utc_today())
    assert Enum.any?(meals, &(&1.recipe_id == recipe.id))
  end

  defp issue_token(conn, params) do
    response = conn |> post("/api/auth/token", params) |> json_response(200)
    response["access_token"]
  end
end
