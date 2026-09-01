defmodule MealPlannerApiWeb.AccountLifecycleControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.EmailCodeAuth

  # Phase 4 task 4.1 — the `SwitchAccountAuth` pipeline routes through
  # the legacy `:auth` path when no `continuation_token` is in the
  # body, and through `EmailCodeAuth.exchange_continuation/3` when it
  # is. The continuation exchange only mints `access_v2` (it does
  # NOT mint the legacy `access` typ), so we flip the v2-only flag
  # inside the continuation describe block to keep the issued JWT
  # shape consistent with the rest of the email-code flow.
  describe "POST /api/auth/switch-account (task 3.5)" do
    test "a multi-familia User can switch to a second :active Account", %{conn: conn} do
      user =
        user_with_memberships(%{email: "switcher_a@example.com"}, [
          {%{plan: :family_4, name: "Family Switch A1"}, :owner},
          {%{plan: :individual, name: "Family Switch A2"}, :owner}
        ])

      [membership_1, membership_2] = user.memberships
      token = issue_access_v2_token(user, membership_1)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/auth/switch-account", %{"membership_id" => membership_2.id})

      body = json_response(conn, 200)

      assert is_binary(body["access_token"])
      assert body["membership"]["account_id"] == membership_2.account_id
      assert body["account"]["id"] == membership_2.account_id
    end

    test "switching to another User's membership returns 403 not_your_membership", %{
      conn: conn
    } do
      user =
        user_with_memberships(%{email: "switcher_b@example.com"}, [
          {%{plan: :family_4, name: "Family Switch B"}, :owner}
        ])

      [membership_b] = user.memberships
      token = issue_access_v2_token(user, membership_b)

      other_user =
        user_with_memberships(%{email: "switcher_other@example.com"}, [
          {%{plan: :individual, name: "Other's Account"}, :owner}
        ])

      [other_membership] = other_user.memberships

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/auth/switch-account", %{"membership_id" => other_membership.id})

      assert json_response(conn, 403)["error"] == "not_your_membership"
    end

    test "switching to a :suspended membership returns 409 membership_not_active", %{
      conn: conn
    } do
      user =
        user_with_memberships(%{email: "switcher_c@example.com"}, [
          {%{plan: :family_4, name: "Family Switch C1"}, :owner}
        ])

      [membership_c1] = user.memberships
      token = issue_access_v2_token(user, membership_c1)

      other_owner =
        user_with_memberships(%{email: "switcher_c_other_owner@example.com"}, [
          {%{plan: :individual, name: "Family Switch C2"}, :owner}
        ])

      [other_owner_membership] = other_owner.memberships

      suspended_membership =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: other_owner_membership.account_id,
          user_id: user.id,
          role: :member,
          status: :suspended,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/auth/switch-account", %{"membership_id" => suspended_membership.id})

      assert json_response(conn, 409)["error"] == "membership_not_active"
    end
  end

  # Post-review fix pass, item 2: `switch_account/2` must consult the
  # same `MEAL_PLANNER_TENANCY_V2` flag `auth_controller.ex` uses, instead
  # of unconditionally minting `access_v2` regardless of the flag.
  describe "tenancy_v2_only flag (post-review fix)" do
    setup do
      previous = Application.get_env(:meal_planner_api, :tenancy_v2_only)

      on_exit(fn ->
        Application.put_env(:meal_planner_api, :tenancy_v2_only, previous)
      end)

      :ok
    end

    test "switch_account mints access (not access_v2) when the flag is off", %{conn: conn} do
      user =
        user_with_memberships(%{email: "switcher_flagoff@example.com"}, [
          {%{plan: :family_4, name: "Family Switch FlagOff 1"}, :owner},
          {%{plan: :individual, name: "Family Switch FlagOff 2"}, :owner}
        ])

      [membership_1, membership_2] = user.memberships
      token = issue_access_v2_token(user, membership_1)

      Application.put_env(:meal_planner_api, :tenancy_v2_only, false)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/auth/switch-account", %{"membership_id" => membership_2.id})

      body = json_response(conn, 200)
      {:ok, claims} = Guardian.decode_and_verify(body["access_token"])

      assert claims["typ"] == "access"
      refute Map.has_key?(claims, "membership_id")
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 4 task 4.1 — Conditional switch-account (continuation mode).
  # ---------------------------------------------------------------------------
  #
  # Coverage (`specs/email-code-authentication/spec.md` §"Selection
  # Continuation Security", `design.md` §"Architecture Decisions" +
  # §"Interfaces / Contracts"):
  #
  #   * `{membership_id, continuation_token}` with NO bearer returns 200 +
  #     `access_v2` (the random continuation IS the credential).
  #   * Same body with a valid bearer for the same User returns 200.
  #   * Same body with a foreign bearer returns 401 `foreign_bearer`.
  #   * Same body with an invalid bearer returns 401.
  #   * Same body with a membership NOT in the continuation's set
  #     returns 403 `not_in_continuation_set`.
  #   * Expired continuation returns 401 `expired_continuation`.
  #   * Reused (consumed) continuation returns 401 `consumed_continuation`.
  #   * Unknown continuation plaintext returns 401 `invalid_continuation`.
  #
  # RED-phase note: each test posts to `/api/auth/switch-account` with a
  # `continuation_token` in the body — neither `Plugs.SwitchAccountAuth`
  # nor the controller's continuation branch exist yet, so the whole
  # describe block fails (401 auth_pipeline unauthorized) until 4.2 GREEN.
  describe "POST /api/auth/switch-account with continuation_token (Phase 4 task 4.1)" do
    setup do
      previous = Application.get_env(:meal_planner_api, :tenancy_v2_only)
      Application.put_env(:meal_planner_api, :tenancy_v2_only, true)
      on_exit(fn -> Application.put_env(:meal_planner_api, :tenancy_v2_only, previous) end)
      :ok
    end

    test "continuation_token + membership_id (bearerless) returns 200 and access_token", %{
      conn: conn
    } do
      user = insert_multi_membership_user!("cont_bearerless@example.com")
      [m1, m2] = user.memberships
      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      conn =
        post(conn, "/api/auth/switch-account", %{
          "membership_id" => to_string(m2.id),
          "continuation_token" => plaintext
        })

      body = json_response(conn, 200)
      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert body["membership"]["account_id"] == to_string(m2.account_id)
      assert body["account"]["id"] == to_string(m2.account_id)

      {:ok, claims} = Guardian.decode_and_verify(body["access_token"])
      assert claims["typ"] == "access_v2"
      assert claims["membership_id"] == Ecto.UUID.cast!(m2.id)
      assert claims["user_id"] == Ecto.UUID.cast!(user.id)

      # Continuation is consumed atomically with the mint.
      consumed =
        Repo.get_by(
          MealPlannerApi.Persistence.Auth.AccountSelectionContinuation,
          user_id: user.id
        )

      refute is_nil(consumed.consumed_at)
    end

    test "continuation_token + valid bearer for the same User returns 200", %{conn: conn} do
      user = insert_multi_membership_user!("cont_bearer_match@example.com")
      [m1, m2] = user.memberships
      token = issue_access_v2_token(user, m1)
      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/auth/switch-account", %{
          "membership_id" => to_string(m2.id),
          "continuation_token" => plaintext
        })

      body = json_response(conn, 200)
      assert is_binary(body["access_token"])
      assert body["membership"]["account_id"] == to_string(m2.account_id)
    end

    test "continuation_token + foreign bearer returns 401 foreign_bearer", %{conn: conn} do
      user_a = insert_multi_membership_user!("cont_a@example.com")
      user_b = insert_multi_membership_user!("cont_b@example.com")
      [a1, a2] = user_a.memberships
      [b1, _b2] = user_b.memberships
      foreign_token = issue_access_v2_token(user_b, b1)
      plaintext = EmailCodeAuth.mint_test_continuation(user_a.id, [a1.id, a2.id])

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> foreign_token)
        |> post("/api/auth/switch-account", %{
          "membership_id" => to_string(a2.id),
          "continuation_token" => plaintext
        })

      assert json_response(conn, 401)["error"] == "foreign_bearer"

      # Continuation is NOT consumed on a foreign-bearer refusal.
      consumed =
        Repo.get_by(
          MealPlannerApi.Persistence.Auth.AccountSelectionContinuation,
          user_id: user_a.id
        )

      assert is_nil(consumed.consumed_at)
    end

    test "continuation_token + invalid bearer returns 401", %{conn: conn} do
      user = insert_multi_membership_user!("cont_bad_bearer@example.com")
      [m1, m2] = user.memberships
      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> post("/api/auth/switch-account", %{
          "membership_id" => to_string(m2.id),
          "continuation_token" => plaintext
        })

      assert conn.status == 401
    end

    test "continuation_token for a membership NOT in the set returns 403 not_in_continuation_set",
         %{conn: conn} do
      user = insert_multi_membership_user!("cont_set@example.com")
      [m1, m2] = user.memberships
      other_user = insert_multi_membership_user!("cont_other@example.com")
      [other_m1, _other_m2] = other_user.memberships
      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      conn =
        post(conn, "/api/auth/switch-account", %{
          "membership_id" => to_string(other_m1.id),
          "continuation_token" => plaintext
        })

      assert json_response(conn, 403)["error"] == "not_in_continuation_set"

      # Continuation is NOT consumed when the membership is outside the set.
      consumed =
        Repo.get_by(
          MealPlannerApi.Persistence.Auth.AccountSelectionContinuation,
          user_id: user.id
        )

      assert is_nil(consumed.consumed_at)
    end

    test "expired continuation_token returns 401 expired_continuation", %{conn: conn} do
      user = insert_multi_membership_user!("cont_expired@example.com")
      [m1, m2] = user.memberships
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      plaintext =
        EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id], expires_at: past)

      conn =
        post(conn, "/api/auth/switch-account", %{
          "membership_id" => to_string(m2.id),
          "continuation_token" => plaintext
        })

      assert json_response(conn, 401)["error"] == "expired_continuation"
    end

    test "reusing a consumed continuation returns 401 consumed_continuation", %{conn: conn} do
      user = insert_multi_membership_user!("cont_replay@example.com")
      [m1, m2] = user.memberships
      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      first =
        post(conn, "/api/auth/switch-account", %{
          "membership_id" => to_string(m2.id),
          "continuation_token" => plaintext
        })

      assert first.status == 200

      second =
        post(conn, "/api/auth/switch-account", %{
          "membership_id" => to_string(m1.id),
          "continuation_token" => plaintext
        })

      assert json_response(second, 401)["error"] == "consumed_continuation"
    end

    test "unknown continuation_token returns 401 invalid_continuation", %{conn: conn} do
      user = insert_multi_membership_user!("cont_invalid@example.com")
      [_m1, m2] = user.memberships

      conn =
        post(conn, "/api/auth/switch-account", %{
          "membership_id" => to_string(m2.id),
          "continuation_token" => "not-a-real-continuation-token"
        })

      assert json_response(conn, 401)["error"] == "invalid_continuation"
    end
  end

  # ---- Phase 4 helpers -------------------------------------------------------

  # Insert a User with exactly two `:active` `:owner` memberships so
  # the continuation tests can pick one of the two ids. Mirrors the
  # `insert_user_with_two_memberships!/1` private helper in
  # `email_code_auth_test.exs` but kept local to avoid leaking test
  # scaffolding into the service test module.
  defp insert_multi_membership_user!(email) do
    user_with_memberships(
      %{email: email, name: "Multi #{email}"},
      [
        {%{plan: :individual, name: "Solo #{email}"}, :owner},
        {%{plan: :family_4, name: "Family #{email}"}, :owner}
      ]
    )
  end
end
