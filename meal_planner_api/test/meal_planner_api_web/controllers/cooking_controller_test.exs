defmodule MealPlannerApiWeb.CookingControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning

  test "start step finish cooking session", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_cook", "account_id" => "acct_cook"})

    {:ok, %{account_id: account_id, user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: "u_cook",
        account_id: "acct_cook",
        account_type: :group
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Cebolla Test Cooking",
        category: :verduras,
        calories_per_100: 40,
        protein_g_per_100: Decimal.new("1.2"),
        carbs_g_per_100: Decimal.new("9.3"),
        fat_g_per_100: Decimal.new("0.1")
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Salsa de prueba",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:dinner]
      })

    {:ok, step} =
      Catalog.add_recipe_step(%{
        recipe_id: recipe.id,
        step_number: 1,
        instructions: "Sofreir cebolla",
        duration_minutes: 8
      })

    {:ok, _recipe_ingredient} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: ingredient.id,
        quantity_milli: 200,
        unit: :g
      })

    {:ok, meal} =
      Planning.schedule_meal(%{
        account_id: account_id,
        date: ~D[2026-03-24],
        slot: :dinner,
        recipe_id: recipe.id,
        is_cooked: false
      })

    start_conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/cooking/start", %{"scheduled_meal_id" => meal.id})

    start_body = json_response(start_conn, 200)
    session_id = start_body["data"]["session_id"]

    assert is_binary(session_id)
    assert start_body["data"]["slot"] == "dinner"
    assert length(start_body["data"]["recipe"]["steps"]) == 1

    step_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/cooking/sessions/#{session_id}/step", %{
        "recipe_step_id" => step.id,
        "status" => "completed",
        "view" => "chat"
      })

    step_body = json_response(step_conn, 200)
    assert step_body["data"]["status"] == "completed"

    finish_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/cooking/sessions/#{session_id}/finish")

    finish_body = json_response(finish_conn, 200)
    assert finish_body["data"]["status"] == "completed"
    assert finish_body["data"]["inventory_mutations"] == 1
  end

  defp issue_token(_conn, params) do
    {:ok, %{user: user, account: account}} = Accounts.find_or_create_identity(params)

    {:ok, token, _claims} =
      Guardian.encode_and_sign(user, Accounts.claims_for(user, account), token_type: "access")

    token
  end
end
