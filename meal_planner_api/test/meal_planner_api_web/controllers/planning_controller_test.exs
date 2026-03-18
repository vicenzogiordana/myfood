defmodule MealPlannerApiWeb.PlanningControllerTest do
  use MealPlannerApiWeb.ConnCase, async: true

  test "requires auth token", %{conn: conn} do
    conn = get(conn, "/api/planning/weekly")

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end

  test "free tier is limited to 3 planning days", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_free", "subscription_tier" => "free"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/planning/weekly")

    body = json_response(conn, 200)

    assert length(body["data"]["days"]) == 3
    assert body["data"]["max_planning_days"] == 3
    assert body["data"]["subscription_tier"] == "free"
  end

  test "premium tier receives 7 planning days", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_premium", "subscription_tier" => "premium"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/planning/weekly")

    body = json_response(conn, 200)

    assert length(body["data"]["days"]) == 7
    assert body["data"]["max_planning_days"] == 7
    assert body["data"]["subscription_tier"] == "premium"
  end

  defp issue_token(conn, params) do
    response = conn |> post("/api/auth/token", params) |> json_response(200)
    response["access_token"]
  end
end
