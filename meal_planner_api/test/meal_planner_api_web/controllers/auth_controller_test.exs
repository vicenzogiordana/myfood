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

  # ----------------------------------------------------------------------
  # Phase A — Tenancy Refactor (PR 3a task 3.8)
  # ----------------------------------------------------------------------
  #
  # `auth_controller.ex` consults `:meal_planner_api, :tenancy_v2_only` to
  # decide whether `password/2` (register + login modes) mints `access_v2`
  # (via `AccountsMembership.claims_for/2`) or the legacy `access_v1`
  # (via `Accounts.claims_for/2`). `refresh/2` MUST preserve whichever
  # `typ` the ORIGINAL token carried, independent of the flag's value at
  # refresh time — no silent re-scoping in either direction.
  describe "tenancy_v2_only flag (task 3.8)" do
    setup do
      previous = Application.get_env(:meal_planner_api, :tenancy_v2_only)

      on_exit(fn ->
        Application.put_env(:meal_planner_api, :tenancy_v2_only, previous)
      end)

      :ok
    end

    test "password register mints access_v2 with membership claims when the flag is on", %{
      conn: conn
    } do
      Application.put_env(:meal_planner_api, :tenancy_v2_only, true)

      conn =
        post(conn, "/api/auth/password", %{
          "mode" => "register",
          "email" => "v2_register@myfood.local",
          "password" => "supersecret123",
          "name" => "V2 Register"
        })

      body = json_response(conn, 200)
      {:ok, claims} = Guardian.decode_and_verify(body["access_token"])

      assert claims["typ"] == "access_v2"
      assert is_binary(claims["membership_id"])
      assert claims["account_id"] == body["account"]["id"]
      assert claims["role"] == "owner"
    end

    test "password login mints access_v2 with membership claims when the flag is on", %{
      conn: conn
    } do
      _ =
        post(conn, "/api/auth/password", %{
          "mode" => "register",
          "email" => "v2_login@myfood.local",
          "password" => "supersecret123",
          "name" => "V2 Login"
        })

      Application.put_env(:meal_planner_api, :tenancy_v2_only, true)

      conn =
        post(conn, "/api/auth/password", %{
          "mode" => "login",
          "email" => "v2_login@myfood.local",
          "password" => "supersecret123"
        })

      body = json_response(conn, 200)
      {:ok, claims} = Guardian.decode_and_verify(body["access_token"])

      assert claims["typ"] == "access_v2"
      assert is_binary(claims["membership_id"])
    end

    test "password register mints access_v1 when the flag is off (regression)", %{conn: conn} do
      Application.put_env(:meal_planner_api, :tenancy_v2_only, false)

      conn =
        post(conn, "/api/auth/password", %{
          "mode" => "register",
          "email" => "v1_register_flagoff@myfood.local",
          "password" => "supersecret123",
          "name" => "V1 Register"
        })

      body = json_response(conn, 200)
      {:ok, claims} = Guardian.decode_and_verify(body["access_token"])

      assert claims["typ"] == "access"
      refute Map.has_key?(claims, "membership_id")
    end

    test "refresh preserves access_v2 typ across rotation, regardless of the flag at refresh time",
         %{conn: conn} do
      Application.put_env(:meal_planner_api, :tenancy_v2_only, true)

      register_body =
        conn
        |> post("/api/auth/password", %{
          "mode" => "register",
          "email" => "v2_refresh@myfood.local",
          "password" => "supersecret123",
          "name" => "V2 Refresh"
        })
        |> json_response(200)

      {:ok, original_claims} = Guardian.decode_and_verify(register_body["access_token"])
      original_membership_id = original_claims["membership_id"]

      # Flip the flag OFF before refreshing — the refreshed access token
      # must still be access_v2 because the ORIGINAL token was access_v2.
      Application.put_env(:meal_planner_api, :tenancy_v2_only, false)

      refresh_body =
        conn
        |> post("/api/auth/refresh", %{"refresh_token" => register_body["refresh_token"]})
        |> json_response(200)

      {:ok, refreshed_claims} = Guardian.decode_and_verify(refresh_body["access_token"])

      assert refreshed_claims["typ"] == "access_v2"
      assert refreshed_claims["membership_id"] == original_membership_id
    end

    test "refresh preserves access_v1 typ across rotation, regardless of the flag at refresh time",
         %{conn: conn} do
      Application.put_env(:meal_planner_api, :tenancy_v2_only, false)

      register_body =
        conn
        |> post("/api/auth/password", %{
          "mode" => "register",
          "email" => "v1_refresh@myfood.local",
          "password" => "supersecret123",
          "name" => "V1 Refresh"
        })
        |> json_response(200)

      # Flip the flag ON before refreshing — the refreshed access token
      # must still be access_v1 because the ORIGINAL token was access_v1.
      Application.put_env(:meal_planner_api, :tenancy_v2_only, true)

      refresh_body =
        conn
        |> post("/api/auth/refresh", %{"refresh_token" => register_body["refresh_token"]})
        |> json_response(200)

      {:ok, refreshed_claims} = Guardian.decode_and_verify(refresh_body["access_token"])

      assert refreshed_claims["typ"] == "access"
      refute Map.has_key?(refreshed_claims, "membership_id")
    end
  end

  # ----------------------------------------------------------------------
  # Post-review fix pass, item 8 (security)
  # ----------------------------------------------------------------------
  #
  # Guardian's `token_type:` option at `decode_and_verify` time is NEVER
  # actually checked by Guardian itself — it is only consumed at ENCODE
  # time. Without an explicit `claims["typ"] == "refresh"` assertion,
  # any validly-signed `access` or `access_v2` token could be POSTed as
  # `refresh_token` and would be accepted, minting a fresh long-lived
  # refresh+access pair from a short-lived access token.
  describe "refresh token typ validation (post-review fix, item 8)" do
    test "an access token posted as refresh_token is rejected", %{conn: conn} do
      register_body =
        conn
        |> post("/api/auth/password", %{
          "mode" => "register",
          "email" => "access_as_refresh@myfood.local",
          "password" => "supersecret123",
          "name" => "Access As Refresh"
        })
        |> json_response(200)

      access_token = register_body["access_token"]
      {:ok, access_claims} = Guardian.decode_and_verify(access_token)
      assert access_claims["typ"] == "access"

      conn = post(conn, "/api/auth/refresh", %{"refresh_token" => access_token})

      assert json_response(conn, 401)["error"] == "invalid_refresh_token"
    end

    # Second post-review fix pass: `refresh/2`'s `case` only has 3 clauses —
    # `{:ok, %{"typ" => "refresh"} = claims}`, `{:ok, %{"typ" => other_typ}}`,
    # `{:error, reason}`. A claims map with NO `"typ"` key at all matches
    # neither `:ok` clause, raising `CaseClauseError` (500) instead of the
    # intended fail-closed 401. `Guardian.build_claims/3`'s `set_type/3`
    # always injects a `"typ"` if the claims map passed to `encode_and_sign/3`
    # doesn't already carry one, so a normal mint can never produce this
    # shape — we bypass `build_claims/3` entirely via the lower-level
    # `Guardian.Token.Jwt.create_token/3` (raw sign, no claim post-processing)
    # to reproduce a token whose decoded claims genuinely lack `"typ"`.
    test "a refresh token whose claims are missing typ entirely returns 401, not a crash", %{
      conn: conn
    } do
      {:ok, typeless_token} =
        Elixir.Guardian.Token.Jwt.create_token(Guardian, %{"sub" => Ecto.UUID.generate()}, [])

      {:ok, decoded_claims} =
        Guardian.decode_and_verify(typeless_token, %{}, token_type: "refresh")

      refute Map.has_key?(decoded_claims, "typ")

      conn = post(conn, "/api/auth/refresh", %{"refresh_token" => typeless_token})

      assert json_response(conn, 401)["error"] == "invalid_refresh_token"
    end
  end
end
