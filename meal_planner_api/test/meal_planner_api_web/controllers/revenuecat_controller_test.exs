defmodule MealPlannerApiWeb.RevenuecatControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Accounts, as: DomainAccounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts, as: AccountsPersistence

  # ─── Phase A — Tenancy Refactor (PR 3c task 3.20) ───────────────────────────
  # `webhook/2` is deliberately unauthenticated (no `:auth` pipe) — it is
  # NOT part of this sweep. `sync/2` IS behind `:auth`; see
  # calendar_controller_test.exs (task 3.14) for why a tampered
  # `account_id` claim is the genuine RED-discriminating case for it.
  describe "multi-familia tenancy scoping (task 3.20)" do
    test "POST /api/billing/revenuecat/sync upserts via current_membership.account_id, not a tampered account_id claim",
         %{conn: conn} do
      user =
        user_with_memberships(%{email: "rc_tamper@example.com"}, [
          {%{plan: :family_4, name: "RC Tamper Account A"}, :owner},
          {%{plan: :family_4, name: "RC Tamper Account B"}, :member}
        ])

      [membership_a, membership_b] = user.memberships

      tampered_claims =
        MealPlannerApi.AccountsMembership.claims_for(user, membership_a)
        |> Map.put("account_id", to_string(membership_b.account_id))

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, tampered_claims, token_type: "access")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/billing/revenuecat/sync", %{
          "rc_app_user_id" => "rc_tamper_user",
          "event_id" => "evt_tamper_1",
          "entitlements" => []
        })

      _ = json_response(conn, 200)

      customer =
        AccountsPersistence.get_revenuecat_customer_by_app_user_id("rc_tamper_user")

      assert customer.account_id == membership_a.account_id
      refute customer.account_id == membership_b.account_id
    end
  end

  test "sync endpoint upserts customer and entitlements", %{conn: conn} do
    token =
      issue_token(conn, %{
        "mode" => "register",
        "email" => "u_rc_sync@myfood.local",
        "password" => "supersecret123",
        "name" => "U RC Sync",
        "account_type" => "group"
      })

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/billing/revenuecat/sync", %{
        "rc_app_user_id" => "rc_user_sync_1",
        "event_id" => "evt_sync_1",
        "entitlements" => [
          %{
            "entitlement_id" => "pro",
            "product_identifier" => "myfood_premium_monthly",
            "is_active" => true,
            "will_renew" => true,
            "store" => "app_store",
            "purchase_date" => "2026-03-23T12:00:00Z",
            "expiration_date" => "2030-04-23T12:00:00Z"
          }
        ]
      })

    body = json_response(conn, 200)
    assert body["data"]["processed_entitlements"] == 1
    assert body["data"]["tier"] == "premium"

    customer = AccountsPersistence.get_revenuecat_customer_by_app_user_id("rc_user_sync_1")
    assert customer != nil
  end

  test "webhook endpoint records event", %{conn: _conn} do
    {:ok, register_payload} =
      DomainAccounts.register_with_password(%{
        "email" => "u_rc_hook@myfood.local",
        "password" => "supersecret123",
        "name" => "U RC Hook",
        "account_type" => "group"
      })

    {:ok, _customer} =
      AccountsPersistence.upsert_revenuecat_customer(%{
        account_id: register_payload.account.id,
        user_id: register_payload.user.id,
        rc_app_user_id: "rc_user_hook_1"
      })

    conn =
      build_conn()
      |> post("/api/billing/revenuecat/webhook", %{
        "id" => "evt_webhook_1",
        "type" => "INITIAL_PURCHASE",
        "app_user_id" => "rc_user_hook_1",
        "entitlements" => [
          %{
            "entitlement_id" => "pro",
            "product_identifier" => "myfood_premium_monthly",
            "is_active" => true,
            "store" => "app_store"
          }
        ]
      })

    body = json_response(conn, 200)
    assert body["data"]["event_id"] == "evt_webhook_1"
    assert body["data"]["processed_entitlements"] == 1
  end

  test "auth token uses premium tier from active entitlement", %{conn: conn} do
    register_payload = %{
      "mode" => "register",
      "email" => "u_rc_auth@myfood.local",
      "password" => "supersecret123",
      "name" => "U RC Auth",
      "account_type" => "group"
    }

    token = issue_token(conn, register_payload)

    sync_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/billing/revenuecat/sync", %{
        "rc_app_user_id" => "rc_user_auth_1",
        "entitlements" => [
          %{
            "entitlement_id" => "pro",
            "product_identifier" => "myfood_premium_monthly",
            "is_active" => true
          }
        ]
      })

    _ = json_response(sync_conn, 200)

    auth_conn =
      build_conn()
      |> post("/api/auth/password", %{
        "mode" => "login",
        "email" => "u_rc_auth@myfood.local",
        "password" => "supersecret123",
        "subscription_tier" => "free"
      })

    body = json_response(auth_conn, 200)
    assert body["subscription"]["tier"] == "premium"

    {:ok, claims} = Guardian.decode_and_verify(body["access_token"])
    assert claims["subscription_tier"] == "premium"
  end

  defp issue_token(conn, params) do
    response = conn |> post("/api/auth/password", params) |> json_response(200)
    response["access_token"]
  end
end
