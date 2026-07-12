defmodule MealPlannerApiWeb.CrossAccountIsolationTest do
  @moduledoc """
  Phase A — Tenancy Refactor (PR 3c task 3.23) — the load-bearing,
  end-to-end proof that multi-familia isolation works, per design.md
  §8.5.

  A single User has `:owner` membership in Account A and `:member`
  membership in Account B. Every check below goes through real HTTP
  (`ConnCase`), never an internal context call directly.

  ## Route mapping note

  The launch prompt lists `GET /api/planning`, `GET /api/cooking`, and
  `GET /api/shopping` as checkpoints. None of those three literal routes
  exist in `router.ex` — the closest real GET routes are used instead:
  `GET /api/planning/weekly`, `GET /api/cooking/sessions/:session_id`,
  and `GET /api/shopping-list`. This is documented explicitly rather
  than silently substituted.

  ## `403 account_mismatch` vs. `current_membership`-based scoping

  Only `GET /api/accounts/:account_id/memberships` has an `:account_id`
  segment in its URL, so it is the only route in this test that can
  produce `EnforceAccountScope`'s `403 account_mismatch` (a URL-vs-JWT
  tenancy mismatch, per task 3.7). `GET /api/calendar`,
  `GET /api/planning/weekly`, `GET /api/cooking/sessions/:session_id`,
  `GET /api/inventory`, and `GET /api/shopping-list` carry no
  `:account_id` in their URL at all (per `router.ex`) — for these, the
  isolation guarantee this test proves is the one tasks 3.14-3.20
  established: `current_membership.account_id` (never
  `current_user.account_id`) is the ONLY thing that decides which
  Account's data comes back. A token scoped to Account A must never see
  Account B's calendar meals, planning candidates, cooking sessions,
  inventory items, or shopping items — and vice versa after
  `switch-account`.
  """

  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Persistence.Shopping

  setup do
    user =
      user_with_memberships(%{email: "cross_account_isolation@example.com"}, [
        {%{plan: :family_4, name: "Cross-Account Isolation — Account A"}, :owner},
        {%{plan: :family_4, name: "Cross-Account Isolation — Account B"}, :member}
      ])

    [membership_a, membership_b] = user.memberships

    fixtures_a = seed_account_fixtures(user, membership_a, "A")
    fixtures_b = seed_account_fixtures(user, membership_b, "B")

    %{
      user: user,
      membership_a: membership_a,
      membership_b: membership_b,
      fixtures_a: fixtures_a,
      fixtures_b: fixtures_b
    }
  end

  test "an Account-A-scoped token never sees Account B, and switch-account correctly re-scopes every route",
       %{
         conn: conn,
         user: user,
         membership_a: membership_a,
         membership_b: membership_b,
         fixtures_a: fixtures_a,
         fixtures_b: fixtures_b
       } do
    token_a = issue_access_v2_token(user, membership_a)
    conn_a = put_req_header(conn, "authorization", "Bearer " <> token_a)

    # ── 1. GET /api/accounts/:account_id/memberships — the one route
    # with :account_id in the URL. Cross-Account access is rejected by
    # EnforceAccountScope with 403 account_mismatch (task 3.7); own
    # Account access succeeds.
    mismatch_conn = get(conn_a, "/api/accounts/#{membership_b.account_id}/memberships")
    assert json_response(mismatch_conn, 403)["error"] == "account_mismatch"

    own_conn = get(conn_a, "/api/accounts/#{membership_a.account_id}/memberships")
    assert %{"memberships" => [_ | _]} = json_response(own_conn, 200)

    # ── 2-6. The 5 data routes — no :account_id in the URL, so isolation
    # comes entirely from current_membership.account_id (tasks 3.14-3.20).
    assert_scoped_to(conn_a, fixtures_a, fixtures_b)

    # ── 7. switch-account succeeds and re-issues a token scoped to B.
    switch_conn =
      post(conn_a, "/api/auth/switch-account", %{"membership_id" => membership_b.id})

    switch_body = json_response(switch_conn, 200)
    assert is_binary(switch_body["access_token"])
    assert switch_body["membership"]["account_id"] == membership_b.account_id

    token_b = switch_body["access_token"]
    conn_b = put_req_header(conn, "authorization", "Bearer " <> token_b)

    # ── 8. The SAME 5 routes now return Account B's data exclusively.
    assert_scoped_to(conn_b, fixtures_b, fixtures_a)
  end

  # ---------------------------------------------------------------------
  # Fixture seeding — one full "one item per surface" fixture set per
  # Account, with a `label` (e.g. "A"/"B") baked into every name so
  # cross-Account leakage is trivially detectable by name/id.
  # ---------------------------------------------------------------------

  defp seed_account_fixtures(user, membership, label) do
    account_id = membership.account_id
    today = Date.utc_today()

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Cross-Account Ingredient #{label} #{Ecto.UUID.generate()}",
        category: :verduras,
        calories_per_100: 40,
        protein_g_per_100: Decimal.new("1.2"),
        carbs_g_per_100: Decimal.new("9.3"),
        fat_g_per_100: Decimal.new("0.1")
      })

    {:ok, breakfast_recipe} =
      Catalog.create_recipe(%{
        name: "Cross-Account Breakfast Recipe #{label}",
        account_id: account_id,
        created_by_user_id: user.id,
        source: :user_created,
        servings: 2,
        calories_per_serving: 300,
        prep_time_minutes: 10,
        suitable_for_slots: [:breakfast]
      })

    {:ok, dinner_recipe} =
      Catalog.create_recipe(%{
        name: "Cross-Account Dinner Recipe #{label}",
        account_id: account_id,
        created_by_user_id: user.id,
        source: :user_created,
        servings: 2,
        calories_per_serving: 500,
        prep_time_minutes: 20,
        suitable_for_slots: [:dinner]
      })

    {:ok, _calendar_meal} =
      MealPlannerApi.Persistence.Calendar.upsert_scheduled_meal(account_id, %{
        date: today,
        slot: :breakfast,
        recipe_id: breakfast_recipe.id
      })

    {:ok, dinner_meal} =
      Planning.schedule_meal(%{
        account_id: account_id,
        date: today,
        slot: :dinner,
        recipe_id: dinner_recipe.id,
        is_cooked: false
      })

    {:ok, cooking_session} =
      Planning.create_cooking_session(%{
        account_id: account_id,
        scheduled_meal_id: dinner_meal.id,
        status: :active,
        started_at: DateTime.utc_now(),
        context_snapshot: %{}
      })

    {:ok, _inventory_seed} =
      MealPlannerApi.Persistence.Inventory.apply_delta_and_log(%{
        account_id: account_id,
        ingredient_id: ingredient.id,
        unit: :g,
        source_kind: :planned,
        delta: 500,
        source_user_id: user.id,
        trigger_type: :purchase,
        operation: :add
      })

    {:ok, _shopping_item} =
      Shopping.create_shopping_item(%{
        account_id: account_id,
        scheduled_meal_id: dinner_meal.id,
        planned_date: today,
        ingredient_id: ingredient.id,
        quantity_milli: 250,
        unit: :g,
        status: :pending
      })

    %{
      label: label,
      today: today,
      ingredient_id: ingredient.id,
      breakfast_recipe_id: breakfast_recipe.id,
      dinner_recipe_id: dinner_recipe.id,
      cooking_session_id: cooking_session.id
    }
  end

  # ---------------------------------------------------------------------
  # Shared assertions — `own` is the fixture set that MUST be visible
  # through `conn`, `other` is the fixture set that MUST NOT leak.
  # ---------------------------------------------------------------------

  defp assert_scoped_to(conn, own, other) do
    assert_calendar_scoped(conn, own, other)
    assert_planning_weekly_scoped(conn, own, other)
    assert_cooking_scoped(conn, own, other)
    assert_inventory_scoped(conn, own, other)
    assert_shopping_scoped(conn, own, other)
  end

  defp assert_calendar_scoped(conn, own, other) do
    resp =
      get(conn, "/api/calendar", %{
        "start_date" => Date.to_iso8601(own.today),
        "end_date" => Date.to_iso8601(Date.add(own.today, 1))
      })

    body = json_response(resp, 200)
    recipe_ids = Enum.map(body["data"]["meals"], & &1["recipe_id"])

    # Post-PR-3c review — WARNING fix: `own.breakfast_recipe_id` is
    # written via `Calendar.upsert_scheduled_meal/2` and
    # `own.dinner_recipe_id` via `Planning.schedule_meal/1` — two
    # different write paths into `scheduled_meals`, both read by this
    # same `GET /api/calendar` call. An `or` here would let a regression
    # that broke visibility for only ONE of the two paths go uncaught
    # (the other fixture alone would satisfy the assertion). `and` proves
    # both write paths are independently visible under the correct scope.
    assert own.breakfast_recipe_id in recipe_ids and own.dinner_recipe_id in recipe_ids
    refute other.breakfast_recipe_id in recipe_ids
    refute other.dinner_recipe_id in recipe_ids
  end

  defp assert_planning_weekly_scoped(conn, own, other) do
    resp = get(conn, "/api/planning/weekly")
    body = json_response(resp, 200)

    breakfast_recipe_ids =
      body["data"]["days"]
      |> Enum.flat_map(& &1["meals"])
      |> Enum.filter(&(&1["slot"] == "breakfast"))
      |> Enum.map(& &1["recipe_id"])

    assert own.breakfast_recipe_id in breakfast_recipe_ids
    refute other.breakfast_recipe_id in breakfast_recipe_ids
  end

  defp assert_cooking_scoped(conn, own, other) do
    own_resp = get(conn, "/api/cooking/sessions/#{own.cooking_session_id}")
    assert %{"data" => %{"session_id" => session_id}} = json_response(own_resp, 200)
    assert session_id == own.cooking_session_id

    other_resp = get(conn, "/api/cooking/sessions/#{other.cooking_session_id}")
    assert json_response(other_resp, 404)["error"] == "session_not_found"
  end

  defp assert_inventory_scoped(conn, own, other) do
    resp = get(conn, "/api/inventory")
    body = json_response(resp, 200)

    all_ids =
      (body["data"]["sections"]["ok"] ++
         body["data"]["sections"]["warning"] ++ body["data"]["sections"]["expired"])
      |> Enum.map(& &1["ingredient_id"])

    assert own.ingredient_id in all_ids
    refute other.ingredient_id in all_ids
  end

  defp assert_shopping_scoped(conn, own, other) do
    resp =
      get(conn, "/api/shopping-list", %{
        "from_date" => Date.to_iso8601(own.today),
        "to_date" => Date.to_iso8601(Date.add(own.today, 1))
      })

    body = json_response(resp, 200)
    all_ids = Enum.map(body["data"]["items"], & &1["ingredient_id"])

    assert own.ingredient_id in all_ids
    refute other.ingredient_id in all_ids
  end
end
