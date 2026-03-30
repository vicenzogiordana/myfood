defmodule MealPlannerApiWeb.PlanningChatControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false
  import Ecto.Query

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Calendar
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Repo

  test "planning chat creates a proposal and confirms scheduled meals", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_chat", "account_id" => "acct_chat"})

    {:ok, %{account_id: account_id, user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: "u_chat",
        account_id: "acct_chat",
        account_type: :group
      })

    {:ok, breakfast_recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Avena chat",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:breakfast]
      })

    {:ok, lunch_recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Tacos vegetarianos",
        source: :user_created,
        servings: 4,
        suitable_for_slots: [:lunch]
      })

    {:ok, dinner_recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Sopa chat",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:dinner]
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/planning/chat", %{
        "message" => "Necesito menu para la semana",
        "date_from" => "2026-03-23",
        "date_to" => "2026-03-24",
        "requested_recipe_ids" => [breakfast_recipe.id, lunch_recipe.id, dinner_recipe.id],
        "kcal_target" => 2200,
        "weekly_budget_cents" => 90_000
      })

    body = json_response(conn, 200)

    proposal_id = body["data"]["proposal_id"]

    assert is_binary(proposal_id)
    assert length(body["data"]["proposal"]["scheduled_meals"]) == 6
    assert is_map(body["data"]["proposal"]["weekly_plan"])
    assert length(body["data"]["proposal"]["weekly_plan"]["days"]) >= 2

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/planning/proposals/#{proposal_id}/confirm")

    confirm_body = json_response(conn, 200)

    assert confirm_body["data"]["status"] == "confirmed"
    assert confirm_body["data"]["scheduled_meals_count"] == 6

    assert Repo.aggregate(
             from(m in ScheduledMeal, where: m.account_id == ^account_id),
             :count,
             :id
           ) ==
             6
  end

  test "favorites endpoint returns user starred recipes", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_fav", "account_id" => "acct_fav"})

    {:ok, %{account_id: account_id, user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: "u_fav",
        account_id: "acct_fav",
        account_type: :group
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Empanadas de choclo",
        source: :user_created,
        servings: 8,
        suitable_for_slots: [:dinner]
      })

    {:ok, true} = Calendar.toggle_favorite(account_id, user_id, recipe.id)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/planning/favorites?limit=5")

    body = json_response(conn, 200)

    assert Enum.any?(body["data"], &(&1["recipe_id"] == recipe.id))
  end

  defp issue_token(_conn, params) do
    {:ok, %{user: user, account: account}} = Accounts.find_or_create_identity(params)

    {:ok, token, _claims} =
      Guardian.encode_and_sign(user, Accounts.claims_for(user, account), token_type: "access")

    token
  end
end
