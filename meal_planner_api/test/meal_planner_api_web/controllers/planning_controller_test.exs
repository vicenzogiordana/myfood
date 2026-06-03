defmodule MealPlannerApiWeb.PlanningControllerTest do
  use MealPlannerApiWeb.ConnCase, async: true

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Planning

  test "requires auth token", %{conn: conn} do
    conn = get(conn, "/api/planning/weekly")

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end

  test "account plan returns 7 planning days", %{conn: conn} do
    token =
      issue_token(conn, %{
        "user_id" => "u_free",
        "account_id" => "acct_free",
        "subscription_tier" => "premium"
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/planning/weekly")

    body = json_response(conn, 200)

    assert length(body["data"]["days"]) == 7
    assert body["data"]["max_planning_days"] == 7
    assert body["data"]["subscription_tier"] == "premium"
  end

  test "premium tier receives 7 planning days", %{conn: conn} do
    token =
      issue_token(conn, %{
        "user_id" => "u_premium",
        "account_id" => "acct_premium",
        "subscription_tier" => "premium"
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/planning/weekly")

    body = json_response(conn, 200)

    assert length(body["data"]["days"]) == 7
    assert body["data"]["max_planning_days"] == 7
    assert body["data"]["subscription_tier"] == "premium"
  end

  test "weekly endpoint rejects days exceeding account max", %{conn: conn} do
    token =
      issue_token(conn, %{
        "user_id" => "u_days_exceeded",
        "account_id" => "acct_days_exceeded",
        "subscription_tier" => "free"
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/planning/weekly", %{"days" => 8})

    body = json_response(conn, 400)
    assert body["error"] == "exceeds_max_planning_days"
  end

  test "confirm endpoint persists scheduled meals", %{conn: conn} do
    token =
      issue_token(conn, %{
        "user_id" => "u_plan_confirm",
        "account_id" => "acct_plan_confirm",
        "subscription_tier" => "premium"
      })

    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "u_plan_confirm",
        "account_id" => "acct_plan_confirm",
        "subscription_tier" => "premium",
        "account_type" => "group"
      })

    {:ok, breakfast} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Desayuno confirm",
        source: :user_created,
        servings: 1,
        calories_per_serving: 420,
        suitable_for_slots: [:breakfast]
      })

    {:ok, lunch} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Almuerzo confirm",
        source: :user_created,
        servings: 1,
        calories_per_serving: 730,
        suitable_for_slots: [:lunch]
      })

    today = Date.utc_today()
    tomorrow = Date.add(today, 1)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/planning/confirm", %{
        "meals" => [
          %{"date" => Date.to_iso8601(today), "slot" => "breakfast", "recipe_id" => breakfast.id},
          %{"date" => Date.to_iso8601(tomorrow), "slot" => "lunch", "recipe_id" => lunch.id}
        ]
      })

    body = json_response(conn, 200)
    assert body["data"]["scheduled_meals_count"] == 2

    persisted = Planning.list_scheduled_meals(account.id, today, tomorrow)
    assert length(persisted) == 2
  end

  test "confirm endpoint rejects invalid payload", %{conn: conn} do
    token =
      issue_token(conn, %{
        "user_id" => "u_plan_bad",
        "account_id" => "acct_plan_bad",
        "subscription_tier" => "free"
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/planning/confirm", %{"meals" => "invalid"})

    body = json_response(conn, 400)
    assert body["error"] == "invalid_payload"
  end

  defp issue_token(_conn, params) do
    {:ok, %{user: user, account: account}} = Accounts.find_or_create_identity(params)

    requested_tier =
      params
      |> Map.get("subscription_tier", "free")
      |> MealPlannerApi.Subscriptions.normalize_tier()

    user = Map.put(user, :subscription_tier, requested_tier)
    account = Map.put(account, :subscription_tier, requested_tier)

    {:ok, token, _claims} =
      Guardian.encode_and_sign(user, Accounts.claims_for(user, account), token_type: "access")

    token
  end
end
