defmodule MealPlannerApiWeb.AuthControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Accounts.User

  setup do
    previous_verifier = Application.get_env(:meal_planner_api, :social_verifier)

    Application.put_env(
      :meal_planner_api,
      :social_verifier,
      MealPlannerApi.Auth.SocialVerifierFake
    )

    on_exit(fn ->
      Application.put_env(:meal_planner_api, :social_verifier, previous_verifier)
    end)

    :ok
  end

  test "password register issues token with account and subscription claims", %{conn: conn} do
    conn =
      post(conn, "/api/auth/password", %{
        "mode" => "register",
        "email" => "u_auth@myfood.local",
        "password" => "supersecret123",
        "name" => "U Auth",
        "account_type" => "group",
        "subscription_tier" => "premium"
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
      issue_password_token(conn, %{
        "email" => "u_me@myfood.local",
        "password" => "supersecret123",
        "name" => "U Me",
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
      issue_password_token(conn, %{
        "email" => "u_me_deleted@myfood.local",
        "password" => "supersecret123",
        "name" => "U Me Deleted",
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

  test "password endpoint fails when required fields are missing", %{conn: conn} do
    conn =
      post(conn, "/api/auth/password", %{
        "mode" => "register",
        "email" => "u_missing_password@myfood.local",
        "subscription_tier" => "free"
      })

    body = json_response(conn, 400)
    assert body["error"] == "invalid_password"
  end

  test "social auth issues token for a verified provider identity", %{conn: conn} do
    Process.put(
      {MealPlannerApi.Auth.SocialVerifierFake, :response},
      {:ok,
       %{
         provider: "google",
         provider_user_id: "g_123",
         email: "g_123@myfood.local",
         name: "G User"
       }}
    )

    conn =
      post(conn, "/api/auth/social", %{
        "provider" => "google",
        "id_token" => "google-id-token",
        "subscription_tier" => "free"
      })

    body = json_response(conn, 200)

    assert is_binary(body["access_token"])
    assert body["user"]["email"] == "g_123@myfood.local"
    assert body["websocket"]["params"]["token"] == body["access_token"]
  end

  test "social auth supports facebook provider identity", %{conn: conn} do
    Process.put(
      {MealPlannerApi.Auth.SocialVerifierFake, :response},
      {:ok,
       %{
         provider: "facebook",
         provider_user_id: "fb_123",
         email: "fb_123@myfood.local",
         name: "FB User"
       }}
    )

    conn =
      post(conn, "/api/auth/social", %{
        "provider" => "facebook",
        "id_token" => "facebook-user-token",
        "subscription_tier" => "free"
      })

    body = json_response(conn, 200)

    assert is_binary(body["access_token"])
    assert body["user"]["email"] == "fb_123@myfood.local"
  end

  test "social auth rejects unsupported provider", %{conn: conn} do
    Process.put(
      {MealPlannerApi.Auth.SocialVerifierFake, :response},
      {:error, :unsupported_provider}
    )

    conn =
      post(conn, "/api/auth/social", %{
        "provider" => "twitter",
        "id_token" => "tw-token"
      })

    body = json_response(conn, 401)
    assert body["error"] == "unsupported_provider"
  end

  test "social auth validates required payload", %{conn: conn} do
    conn =
      post(conn, "/api/auth/social", %{
        "provider" => "google"
      })

    body = json_response(conn, 400)
    assert body["error"] == "invalid_social_payload"
  end

  test "password auth register creates user and returns token", %{conn: conn} do
    conn =
      post(conn, "/api/auth/password", %{
        "mode" => "register",
        "email" => "password_user@myfood.local",
        "password" => "supersecret123",
        "name" => "Password User",
        "account_type" => "individual"
      })

    body = json_response(conn, 200)

    assert is_binary(body["access_token"])
    assert body["user"]["email"] == "password_user@myfood.local"
  end

  test "password auth login returns token for existing credentials", %{conn: conn} do
    _register_response =
      conn
      |> post("/api/auth/password", %{
        "mode" => "register",
        "email" => "password_login@myfood.local",
        "password" => "supersecret123",
        "name" => "Password Login User"
      })
      |> json_response(200)

    conn =
      post(conn, "/api/auth/password", %{
        "mode" => "login",
        "email" => "password_login@myfood.local",
        "password" => "supersecret123"
      })

    body = json_response(conn, 200)
    assert is_binary(body["access_token"])
    assert body["user"]["email"] == "password_login@myfood.local"
  end

  test "password auth rejects wrong credentials", %{conn: conn} do
    _register_response =
      conn
      |> post("/api/auth/password", %{
        "mode" => "register",
        "email" => "password_wrong@myfood.local",
        "password" => "supersecret123",
        "name" => "Password Wrong User"
      })
      |> json_response(200)

    conn =
      post(conn, "/api/auth/password", %{
        "mode" => "login",
        "email" => "password_wrong@myfood.local",
        "password" => "wrong-password"
      })

    body = json_response(conn, 401)
    assert body["error"] == "invalid_credentials"
  end

  test "password auth validates minimum password length", %{conn: conn} do
    conn =
      post(conn, "/api/auth/password", %{
        "mode" => "register",
        "email" => "short_pass@myfood.local",
        "password" => "short"
      })

    body = json_response(conn, 400)
    assert body["error"] == "password_too_short"
  end

  defp issue_password_token(conn, params) do
    register_payload =
      Map.merge(
        %{
          "mode" => "register",
          "account_type" => "individual"
        },
        params
      )

    response = conn |> post("/api/auth/password", register_payload) |> json_response(200)
    response["access_token"]
  end
end
