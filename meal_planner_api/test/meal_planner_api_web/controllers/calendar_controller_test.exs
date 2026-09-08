defmodule MealPlannerApiWeb.CalendarControllerTest do
  use MealPlannerApiWeb.ConnCase, async: true

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Calendar
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Accounts.Account

  # ─── Phase A — Tenancy Refactor (PR 3c task 3.14) ───────────────────────────
  # Controller sweep: `CalendarController` must resolve tenancy scope from
  # `conn.assigns.current_membership.account_id` (the DB-resolved,
  # `membership_id`-backed row `LoadCurrentMembership` assigns), not the
  # legacy `current_user.account_id` field — which Guardian's
  # `resource_from_claims/1` re-attaches straight from the JWT's
  # (redundant, non-authoritative) `account_id` claim for dual-write
  # backward compatibility (see `lib/meal_planner_api/auth/guardian.ex`).
  # Because that reattachment already mirrors a well-formed `access_v2`
  # token's `account_id` claim, a naive "JWT scoped to Account_A" test
  # alone cannot distinguish the two fields (it's GREEN either way). The
  # discriminating case is a validly-signed token whose `membership_id`
  # (canonical) and `account_id` claim (redundant, must never be trusted
  # directly) disagree — exactly the shape a stale/legacy claim could take.
  describe "GET /api/calendar — multi-familia tenancy scoping (task 3.14)" do
    setup do
      user =
        user_with_memberships(%{email: "cal_multi_a@example.com"}, [
          {%{plan: :family_4, name: "Calendar Account A"}, :owner},
          {%{plan: :family_4, name: "Calendar Account B"}, :member}
        ])

      [membership_a, membership_b] = user.memberships
      today = Date.utc_today()

      {:ok, recipe_a} =
        Catalog.create_recipe(%{
          name: "Only In Account A",
          account_id: membership_a.account_id,
          created_by_user_id: user.id,
          source: :user_created,
          servings: 2,
          calories_per_serving: 300,
          prep_time_minutes: 10,
          suitable_for_slots: [:lunch]
        })

      {:ok, recipe_b} =
        Catalog.create_recipe(%{
          name: "Only In Account B",
          account_id: membership_b.account_id,
          created_by_user_id: user.id,
          source: :user_created,
          servings: 2,
          calories_per_serving: 300,
          prep_time_minutes: 10,
          suitable_for_slots: [:lunch]
        })

      {:ok, _meal_a} =
        Calendar.upsert_scheduled_meal(membership_a.account_id, %{
          date: today,
          slot: :lunch,
          recipe_id: recipe_a.id
        })

      {:ok, _meal_b} =
        Calendar.upsert_scheduled_meal(membership_b.account_id, %{
          date: today,
          slot: :lunch,
          recipe_id: recipe_b.id
        })

      %{user: user, membership_a: membership_a, membership_b: membership_b, today: today}
    end

    test "JWT scoped to Account_A (via membership_id) returns Account_A data only", %{
      conn: conn,
      user: user,
      membership_a: membership_a,
      today: today
    } do
      token_a = issue_access_v2_token(user, membership_a)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token_a)
        |> get("/api/calendar", %{
          "start_date" => Date.to_iso8601(today),
          "end_date" => Date.to_iso8601(Date.add(today, 6))
        })

      body = json_response(conn, 200)
      recipe_names = Enum.map(body["data"]["meals"], & &1["recipe_name"])

      assert "Only In Account A" in recipe_names
      refute "Only In Account B" in recipe_names
    end

    test "trusts the DB-resolved current_membership.account_id, not a tampered account_id claim",
         %{
           conn: conn,
           user: user,
           membership_a: membership_a,
           membership_b: membership_b,
           today: today
         } do
      # membership_id points at Account A (the canonical scope pointer);
      # the redundant account_id claim is tampered to point at Account B.
      # A controller reading `current_membership.account_id` (resolved via
      # membership_id) must return Account A's data regardless.
      tampered_claims =
        MealPlannerApi.AccountsMembership.claims_for(user, membership_a)
        |> Map.put("account_id", to_string(membership_b.account_id))

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, tampered_claims, token_type: "access")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar", %{
          "start_date" => Date.to_iso8601(today),
          "end_date" => Date.to_iso8601(Date.add(today, 6))
        })

      body = json_response(conn, 200)
      recipe_names = Enum.map(body["data"]["meals"], & &1["recipe_name"])

      assert "Only In Account A" in recipe_names
      refute "Only In Account B" in recipe_names
    end
  end

  # ─── Gap 1: show_slot endpoint ──────────────────────────────────────────────

  describe "GET /api/calendar/slot — filled slot" do
    test "returns meal with can_create: false", %{conn: conn} do
      token =
        issue_token(conn, %{
          "user_id" => "u_slot_filled",
          "account_id" => "acct_slot_filled"
        })

      {:ok, %{account_id: account_id, user_id: user_id}} =
        Identity.ensure_persistent_identity(%{
          id: "u_slot_filled",
          account_id: "acct_slot_filled",
          plan: :family_4
        })

      # Create a recipe and scheduled meal for the target slot
      {:ok, recipe} =
        Catalog.create_recipe(%{
          name: "Pollo a la Plancha Test Slot",
          account_id: account_id,
          created_by_user_id: user_id,
          source: :user_created,
          servings: 2,
          calories_per_serving: 450,
          prep_time_minutes: 20,
          suitable_for_slots: [:lunch]
        })

      {:ok, _meal} =
        Calendar.upsert_scheduled_meal(account_id, %{
          date: ~D[2026-06-15],
          slot: :lunch,
          recipe_id: recipe.id
        })

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar/slot", %{
          "date" => "2026-06-15",
          "slot" => "lunch"
        })

      assert %{
               "data" => %{
                 "meal_id" => meal_id,
                 "can_create" => false,
                 "slot" => "lunch",
                 "recipe_id" => recipe_id
               }
             } = json_response(conn, 200)

      assert is_binary(meal_id)
      assert is_binary(recipe_id)
    end
  end

  describe "GET /api/calendar/slot — empty slot" do
    test "returns can_create: true when no meal exists", %{conn: conn} do
      token =
        issue_token(conn, %{
          "user_id" => "u_slot_empty",
          "account_id" => "acct_slot_empty"
        })

      {:ok, _} =
        Identity.ensure_persistent_identity(%{
          id: "u_slot_empty",
          account_id: "acct_slot_empty",
          plan: :family_4
        })

      # No scheduled meal for 2026-06-20 / dinner
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar/slot", %{
          "date" => "2026-06-20",
          "slot" => "dinner"
        })

      assert %{
               "data" => %{
                 "meal_id" => nil,
                 "can_create" => true,
                 "slot" => "dinner",
                 "recipe_id" => nil,
                 "recipe_name" => nil,
                 "macros" => nil,
                 "prep_time_minutes" => nil,
                 "is_cooked" => false,
                 "is_favorite" => false
               }
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/calendar/slot — validation errors" do
    test "returns 422 for invalid date format", %{conn: conn} do
      token =
        issue_token(conn, %{
          "user_id" => "u_slot_bad_date",
          "account_id" => "acct_slot_bad_date"
        })

      {:ok, _} =
        Identity.ensure_persistent_identity(%{
          id: "u_slot_bad_date",
          account_id: "acct_slot_bad_date",
          plan: :family_4
        })

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar/slot", %{
          "date" => "not-a-date",
          "slot" => "lunch"
        })

      assert %{"error" => "invalid_date_format"} = json_response(conn, 422)
    end

    test "returns 422 for invalid slot value", %{conn: conn} do
      token =
        issue_token(conn, %{
          "user_id" => "u_slot_bad_slot",
          "account_id" => "acct_slot_bad_slot"
        })

      {:ok, _} =
        Identity.ensure_persistent_identity(%{
          id: "u_slot_bad_slot",
          account_id: "acct_slot_bad_slot",
          plan: :family_4
        })

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar/slot", %{
          "date" => "2026-06-15",
          "slot" => "supper"
        })

      assert %{"error" => "invalid_slot"} = json_response(conn, 422)
    end

    test "returns 422 for missing date param", %{conn: conn} do
      token =
        issue_token(conn, %{
          "user_id" => "u_slot_no_date",
          "account_id" => "acct_slot_no_date"
        })

      {:ok, _} =
        Identity.ensure_persistent_identity(%{
          id: "u_slot_no_date",
          account_id: "acct_slot_no_date",
          plan: :family_4
        })

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar/slot", %{"slot" => "lunch"})

      assert %{"error" => "missing_date_param"} = json_response(conn, 422)
    end

    test "returns 422 for missing slot param", %{conn: conn} do
      token =
        issue_token(conn, %{
          "user_id" => "u_slot_no_slot",
          "account_id" => "acct_slot_no_slot"
        })

      {:ok, _} =
        Identity.ensure_persistent_identity(%{
          id: "u_slot_no_slot",
          account_id: "acct_slot_no_slot",
          plan: :family_4
        })

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar/slot", %{"date" => "2026-06-15"})

      assert %{"error" => "missing_slot_param"} = json_response(conn, 422)
    end
  end

  # ─── Gap 3: can_create in index response ─────────────────────────────────────

  describe "GET /api/calendar — can_create in selected_meal" do
    test "selected_meal has can_create: false when slot is filled", %{conn: conn} do
      token =
        issue_token(conn, %{
          "user_id" => "u_idx_filled",
          "account_id" => "acct_idx_filled"
        })

      {:ok, %{account_id: account_id, user_id: user_id}} =
        Identity.ensure_persistent_identity(%{
          id: "u_idx_filled",
          account_id: "acct_idx_filled",
          plan: :family_4
        })

      today = Date.utc_today()

      {:ok, recipe} =
        Catalog.create_recipe(%{
          name: "Ensalada César Test Index",
          account_id: account_id,
          created_by_user_id: user_id,
          source: :user_created,
          servings: 2,
          calories_per_serving: 320,
          prep_time_minutes: 15,
          suitable_for_slots: [:lunch]
        })

      {:ok, _meal} =
        Calendar.upsert_scheduled_meal(account_id, %{
          date: today,
          slot: :lunch,
          recipe_id: recipe.id
        })

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar", %{
          "start_date" => Date.to_iso8601(today),
          "end_date" => Date.to_iso8601(Date.add(today, 6)),
          "selected_date" => Date.to_iso8601(today),
          "selected_slot" => "lunch"
        })

      assert %{
               "data" => %{
                 "selected_meal" => %{
                   "can_create" => false,
                   "meal_id" => meal_id
                 }
               }
             } = json_response(conn, 200)

      assert is_binary(meal_id)
    end

    test "selected_meal has can_create: true when slot is empty", %{conn: conn} do
      token =
        issue_token(conn, %{
          "user_id" => "u_idx_empty",
          "account_id" => "acct_idx_empty"
        })

      {:ok, _} =
        Identity.ensure_persistent_identity(%{
          id: "u_idx_empty",
          account_id: "acct_idx_empty",
          plan: :family_4
        })

      tomorrow = Date.add(Date.utc_today(), 10)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar", %{
          "start_date" => Date.to_iso8601(Date.utc_today()),
          "end_date" => Date.to_iso8601(Date.add(Date.utc_today(), 6)),
          "selected_date" => Date.to_iso8601(tomorrow),
          "selected_slot" => "dinner"
        })

      assert %{
               "data" => %{
                 "selected_meal" => nil
               }
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/calendar — can_create in meals list" do
    test "meals list items have can_create: false", %{conn: conn} do
      token =
        issue_token(conn, %{
          "user_id" => "u_meals_list",
          "account_id" => "acct_meals_list"
        })

      {:ok, %{account_id: account_id, user_id: user_id}} =
        Identity.ensure_persistent_identity(%{
          id: "u_meals_list",
          account_id: "acct_meals_list",
          plan: :family_4
        })

      today = Date.utc_today()

      {:ok, recipe} =
        Catalog.create_recipe(%{
          name: "Tortilla Española Test Meals",
          account_id: account_id,
          created_by_user_id: user_id,
          source: :user_created,
          servings: 2,
          calories_per_serving: 280,
          prep_time_minutes: 10,
          suitable_for_slots: [:breakfast]
        })

      {:ok, _meal} =
        Calendar.upsert_scheduled_meal(account_id, %{
          date: today,
          slot: :breakfast,
          recipe_id: recipe.id
        })

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/calendar", %{
          "start_date" => Date.to_iso8601(today),
          "end_date" => Date.to_iso8601(Date.add(today, 6))
        })

      body = json_response(conn, 200)
      meals = body["data"]["meals"]
      assert is_list(meals)

      for meal <- meals do
        assert Map.has_key?(meal, "can_create"),
               "meal missing can_create field: #{inspect(meal)}"

        assert meal["can_create"] == false,
               "meal can_create should be false: #{inspect(meal)}"
      end
    end
  end

  describe "PUT /api/calendar/meals/range — capability and tenancy" do
    test "denies an expired account when capability enforcement is enabled", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "calendar-expired@example.com"},
          [{%{name: "Expired calendar account", plan: :family_4}, :owner}]
        )

      membership = hd(user.memberships)
      account = Repo.get!(Account, membership.account_id)
      now = DateTime.utc_now()

      account
      |> Account.changeset(%{
        trial_started_at: DateTime.add(now, -86_400, :second),
        trial_ends_at: DateTime.add(now, -1, :second)
      })
      |> Repo.update!()

      token = issue_access_v2_token(user, membership)
      previous = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)
      Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)

      try do
        conn =
          conn
          |> put_req_header("authorization", "Bearer " <> token)
          |> put("/api/calendar/meals/range", %{
            "from" => "2026-07-01",
            "to" => "2026-07-07",
            "meals" => []
          })

        assert %{"error" => "subscription_required"} = json_response(conn, 403)
      after
        Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, previous)
      end
    end

    test "rejects replacement input from another account before writing", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "calendar-controller-scope@example.com"},
          [
            {%{name: "Controller account A", plan: :family_4}, :owner},
            {%{name: "Controller account B", plan: :family_4}, :member}
          ]
        )

      [membership_a, membership_b] = user.memberships

      {:ok, existing} =
        Calendar.upsert_scheduled_meal(membership_b.account_id, %{
          date: ~D[2026-07-02],
          slot: :lunch
        })

      token = issue_access_v2_token(user, membership_a)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> put("/api/calendar/meals/range", %{
          "from" => "2026-07-01",
          "to" => "2026-07-07",
          "meals" => [
            %{
              "account_id" => membership_b.account_id,
              "date" => "2026-07-03",
              "slot" => "dinner"
            }
          ]
        })

      assert %{"error" => "cross_account"} = json_response(conn, 422)

      assert [meal] =
               MealPlannerApi.Data.PlanningRepo.list_scheduled_meals(
                 membership_b.account_id,
                 ~D[2026-07-01],
                 ~D[2026-07-07]
               )

      assert meal.id == existing.id
    end
  end

  describe "PUT /api/calendar/meals/range — happy path and validation" do
    test "replaces meals in the selected range and returns the replaced count", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "calendar-controller-happy@example.com"},
          [{%{name: "Calendar happy path account", plan: :family_4}, :owner}]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> put("/api/calendar/meals/range", %{
          "from" => "2026-07-01",
          "to" => "2026-07-07",
          "meals" => [
            %{"date" => "2026-07-02", "slot" => "lunch"},
            %{"date" => "2026-07-03", "slot" => "dinner"}
          ]
        })

      assert %{"data" => %{"replaced" => 2}} = json_response(conn, 200)

      meals =
        MealPlannerApi.Data.PlanningRepo.list_scheduled_meals(
          membership.account_id,
          ~D[2026-07-01],
          ~D[2026-07-07]
        )

      assert length(meals) == 2
      assert Enum.any?(meals, &(&1.date == ~D[2026-07-02] and &1.slot == :lunch))
      assert Enum.any?(meals, &(&1.date == ~D[2026-07-03] and &1.slot == :dinner))
    end

    test "returns 422 when `from` is missing", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "calendar-controller-missing-from@example.com"},
          [{%{name: "Calendar validation missing-from account", plan: :family_4}, :owner}]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> put("/api/calendar/meals/range", %{
          "to" => "2026-07-07",
          "meals" => []
        })

      assert %{"error" => "missing_date_param"} = json_response(conn, 422)
    end

    test "returns 422 when `to` is not a valid ISO date", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "calendar-controller-bad-to@example.com"},
          [{%{name: "Calendar validation bad-to account", plan: :family_4}, :owner}]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> put("/api/calendar/meals/range", %{
          "from" => "2026-07-01",
          "to" => "not-a-date",
          "meals" => []
        })

      assert %{"error" => "invalid_date_format"} = json_response(conn, 422)
    end

    test "returns 422 when the range is reversed", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "calendar-controller-reversed@example.com"},
          [{%{name: "Calendar validation reversed account", plan: :family_4}, :owner}]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> put("/api/calendar/meals/range", %{
          "from" => "2026-07-07",
          "to" => "2026-07-01",
          "meals" => []
        })

      assert %{"error" => "invalid_date_range"} = json_response(conn, 422)
    end

    test "returns 422 when `meals` is missing", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "calendar-controller-no-meals@example.com"},
          [{%{name: "Calendar validation no-meals account", plan: :family_4}, :owner}]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> put("/api/calendar/meals/range", %{
          "from" => "2026-07-01",
          "to" => "2026-07-07"
        })

      assert %{"error" => "missing_meals"} = json_response(conn, 422)
    end
  end

  # ─── Calendar access — capability enforcement on GET /api/calendar ──────────
  # Spec scenarios: Eligible Account reads its calendar (covered above by
  # the multi-familia tenancy tests + show_slot tests) and Expired Account
  # read is denied (this block).
  describe "GET /api/calendar — capability enforcement" do
    test "denies an expired account when capability enforcement is enabled", %{conn: conn} do
      user =
        user_with_memberships(
          %{email: "calendar-get-expired@example.com"},
          [{%{name: "Expired calendar read account", plan: :family_4}, :owner}]
        )

      membership = hd(user.memberships)
      account = Repo.get!(Account, membership.account_id)
      now = DateTime.utc_now()

      account
      |> Account.changeset(%{
        trial_started_at: DateTime.add(now, -86_400, :second),
        trial_ends_at: DateTime.add(now, -1, :second)
      })
      |> Repo.update!()

      token = issue_access_v2_token(user, membership)
      previous = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)
      Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)

      try do
        today = Date.utc_today()

        conn =
          conn
          |> put_req_header("authorization", "Bearer " <> token)
          |> get("/api/calendar", %{
            "start_date" => Date.to_iso8601(today),
            "end_date" => Date.to_iso8601(Date.add(today, 6))
          })

        assert %{"error" => "subscription_required"} = json_response(conn, 403)
      after
        Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, previous)
      end
    end
  end

  # ─── Helper functions ────────────────────────────────────────────────────────

  defp issue_token(_conn, params) do
    {:ok, %{user: user, account: account}} =
      MealPlannerApi.Accounts.find_or_create_identity(params)

    user =
      user
      |> Map.put(:subscription_tier, String.to_atom(Map.get(params, "subscription_tier", "free")))

    account =
      account
      |> Map.put(:subscription_tier, String.to_atom(Map.get(params, "subscription_tier", "free")))

    {:ok, token, _claims} =
      Guardian.encode_and_sign(user, MealPlannerApi.Accounts.claims_for(user, account),
        token_type: "access"
      )

    token
  end
end
