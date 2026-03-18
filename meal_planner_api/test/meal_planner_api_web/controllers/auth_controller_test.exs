defmodule MealPlannerApiWeb.AuthControllerTest do
  use MealPlannerApiWeb.ConnCase, async: true

  alias MealPlannerApi.Auth.Guardian

  test "issues token with account and subscription claims", %{conn: conn} do
    conn =
      post(conn, "/api/auth/token", %{
        "user_id" => "u_auth",
        "account_id" => "acct_auth",
        "account_type" => "group",
        "subscription_tier" => "premium",
        "email" => "u_auth@myfood.local"
      })

    body = json_response(conn, 200)

    assert is_binary(body["access_token"])
    assert body["subscription"]["tier"] == "premium"
    assert body["subscription"]["max_planning_days"] == 7

    {:ok, claims} = Guardian.decode_and_verify(body["access_token"])
    assert claims["account_id"] == "acct_auth"
    assert claims["account_type"] == "group"
    assert claims["subscription_tier"] == "premium"
  end

  test "authenticated me endpoint returns user and claims", %{conn: conn} do
    token = issue_token(conn, %{"user_id" => "u_me", "subscription_tier" => "free"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/me")

    body = json_response(conn, 200)

    assert body["user"]["id"] == "u_me"
    assert body["user"]["subscription_tier"] == "free"
    assert body["claims"]["subscription_tier"] == "free"
  end

  defp issue_token(conn, params) do
    response = conn |> post("/api/auth/token", params) |> json_response(200)
    response["access_token"]
  end
end
