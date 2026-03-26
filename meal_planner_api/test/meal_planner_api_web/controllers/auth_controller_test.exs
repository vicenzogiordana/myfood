defmodule MealPlannerApiWeb.AuthControllerTest do
  use MealPlannerApiWeb.ConnCase, async: true

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Accounts.User

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
    assert claims["account_id"] == body["account"]["id"]
    assert claims["account_type"] == "group"
    assert claims["subscription_tier"] == "premium"
  end

  test "authenticated me endpoint returns user and claims", %{conn: conn} do
    token =
      issue_token(conn, %{
        "user_id" => "u_me",
        "account_id" => "acct_me",
        "subscription_tier" => "free"
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/me")

    body = json_response(conn, 200)

    assert body["user"]["id"] == body["claims"]["sub"]
    assert body["user"]["subscription_tier"] == "free"
    assert body["claims"]["subscription_tier"] == "free"
  end

  test "authenticated me endpoint rejects token when user no longer exists", %{conn: conn} do
    token =
      issue_token(conn, %{
        "user_id" => "u_me_deleted",
        "account_id" => "acct_me_deleted",
        "subscription_tier" => "free"
      })

    {:ok, claims} = Guardian.decode_and_verify(token)

    persisted_user_id = claims["sub"]
    persisted_user = Repo.get!(User, persisted_user_id)
    Repo.delete!(persisted_user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/me")

    body = json_response(conn, 401)
    assert body["error"] == "unauthorized"
  end

  test "token endpoint fails when identity fields are missing", %{conn: conn} do
    conn =
      post(conn, "/api/auth/token", %{
        "user_id" => "u_missing_account",
        "subscription_tier" => "free"
      })

    body = json_response(conn, 422)
    assert body["error"] == "unable_to_issue_token"
  end

  defp issue_token(conn, params) do
    response = conn |> post("/api/auth/token", params) |> json_response(200)
    response["access_token"]
  end
end
