defmodule MealPlannerApiWeb.PlanningControllerTest do
  use MealPlannerApiWeb.ConnCase, async: true

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Planning

  # ─── Phase A — Tenancy Refactor (PR 3c task 3.15) ───────────────────────────
  # See calendar_controller_test.exs (task 3.14) for why a tampered
  # `account_id` claim — rather than a plain "scoped JWT" — is the genuine
  # RED-discriminating case for this codebase (Guardian re-attaches
  # `account_id` straight from claims for dual-write compatibility, so a
  # well-formed claim alone can't distinguish `current_user.account_id`
  # from `current_membership.account_id`).
  #
  # `GET /api/planning/weekly` is deliberately NOT covered by a dedicated
  # `user_with_memberships/2`-based test here: `PlanningService.
  # generate_weekly_plan/3` routes through the legacy
  # `Identity.ensure_persistent_identity/1` bridge, which mints a
  # *second*, stable-UUID-derived shadow `User` row from `user.email` —
  # colliding with the `users.email` unique index for any User who
  # already has a real row (as every `user_with_memberships/2` fixture
  # does). This is a pre-existing bridge limitation, orthogonal to
  # tenancy scoping and out of PR 3c's scope; the mechanical
  # `current_membership.account_id` fix is still applied to `weekly/2`
  # (same code path as `confirm/2`, proven below), but is only exercised
  # indirectly (via the existing non-multi-familia `weekly` tests further
  # down this file, which keep passing).
  describe "multi-familia tenancy scoping (task 3.15)" do
    test "POST /api/planning/confirm persists via current_membership.account_id, not a tampered account_id claim",
         %{conn: conn} do
      user =
        user_with_memberships(%{email: "plan_confirm_tamper@example.com"}, [
          {%{plan: :family_4, name: "Planning Confirm Account A"}, :owner},
          {%{plan: :family_4, name: "Planning Confirm Account B"}, :member}
        ])

      [membership_a, membership_b] = user.memberships

      {:ok, recipe} =
        Catalog.create_recipe(%{
          name: "Confirm Test Recipe",
          account_id: membership_a.account_id,
          created_by_user_id: user.id,
          source: :user_created,
          servings: 1,
          calories_per_serving: 400,
          prep_time_minutes: 10,
          suitable_for_slots: [:breakfast]
        })

      tampered_claims =
        MealPlannerApi.AccountsMembership.claims_for(user, membership_a)
        |> Map.put("account_id", to_string(membership_b.account_id))

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, tampered_claims, token_type: "access")

      today = Date.utc_today()
      # `PlanningService.save_plan/4` resolves the persisted date from
      # `meal["day"]` (a weekday name), not `meal["date"]` — a
      # pre-existing, unrelated quirk also present in this file's
      # original "confirm endpoint persists scheduled meals" test above.
      # Use an inclusive range so this test isn't coupled to that quirk.
      range_end = Date.add(today, 1)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/planning/confirm", %{
          "meals" => [
            %{"date" => Date.to_iso8601(today), "slot" => "breakfast", "recipe_id" => recipe.id}
          ]
        })

      body = json_response(conn, 200)
      assert body["data"]["scheduled_meals_count"] == 1

      assert Planning.list_scheduled_meals(membership_a.account_id, today, range_end)
             |> length() == 1

      assert Planning.list_scheduled_meals(membership_b.account_id, today, range_end)
             |> length() == 0
    end
  end

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
