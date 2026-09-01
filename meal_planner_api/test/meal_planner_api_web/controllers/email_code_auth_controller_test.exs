defmodule MealPlannerApiWeb.EmailCodeAuthControllerTest do
  @moduledoc """
  Phase 1 — HTTP wiring for email-code authentication:
  `POST /api/auth/email-code/request`.

  Coverage (spec `email-code-authentication/spec.md` §"Code Request and
  Non-Enumerating Storage" + §"Code Request Rate Limits"):

    * Known email: `202 {"status": "sent"}`, a row exists in
      `email_verification_codes`, and one email was delivered.
    * Unknown email: same `202` shape, no row, no delivery — preserves
      the non-enumerating guarantee.
    * Fifth request in an hour is allowed.
    * Sixth request in an hour is rejected with `429 + Retry-After`.

  Phase 2 — Verification and Lockout. Exposes
  `POST /api/auth/email-code/verify` and asserts the principal-bound
  consume, replay-race, lockout, and bearer-validation contracts.

  Phase 4 task 4.2 — Verify response shape is the membership outcome:
    * `:single` → `200 {access_token, refresh_token, membership, …}`
    * `:none` → `200 {access_token, …}` with `membership`/`account`
      absent and a JWT whose `membership_id` claim is missing
      (downstream `LoadCurrentMembership` returns
      `401 membership_id_required`).
    * `:multiple` → `200 {memberships, continuation_token}` and no JWT
      (the client exchanges the continuation at
      `/api/auth/switch-account`).

  RED-phase note: this file references
  `MealPlannerApiWeb.EmailCodeAuthController` and the
  `POST /api/auth/email-code/request` route, both of which did NOT
  exist before Phase 1 GREEN landed.
  """
  use MealPlannerApiWeb.ConnCase, async: false

  import Ecto.Query
  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Auth.EmailVerificationCode
  alias MealPlannerApi.Repo

  setup do
    Bamboo.SentEmail.reset()
    :ok
  end

  describe "POST /api/auth/email-code/request" do
    test "returns 202 sent for a known email and persists a verification row", %{conn: conn} do
      user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "known-controller@example.com",
          name: "Known Controller",
          role: :member
        })
        |> Repo.insert!()

      conn =
        post(conn, "/api/auth/email-code/request", %{
          "email" => "known-controller@example.com"
        })

      assert json_response(conn, 202) == %{"status" => "sent"}

      rows =
        Repo.all(from(r in EmailVerificationCode, where: r.user_id == ^user.id))

      assert length(rows) == 1

      [row] = rows
      assert row.email == "known-controller@example.com"
      assert byte_size(row.code_hash) == 64

      delivered = Bamboo.SentEmail.all()
      assert length(delivered) == 1
      [email] = delivered
      assert email.to == [{"Known Controller", "known-controller@example.com"}]
    end

    test "unknown email returns 202, no row, no delivery", %{conn: conn} do
      conn =
        post(conn, "/api/auth/email-code/request", %{
          "email" => "ghost-controller@example.com"
        })

      assert json_response(conn, 202) == %{"status" => "sent"}

      assert Repo.aggregate(EmailVerificationCode, :count) == 0
      assert Bamboo.SentEmail.all() == []
    end

    test "fifth request for the same email in an hour is allowed", %{conn: conn} do
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{
        email: "five-controller@example.com",
        name: "Five",
        role: :member
      })
      |> Repo.insert!()

      for _ <- 1..5 do
        conn =
          post(conn, "/api/auth/email-code/request", %{
            "email" => "five-controller@example.com"
          })

        assert json_response(conn, 202) == %{"status" => "sent"}
      end

      assert Repo.aggregate(
               from(r in EmailVerificationCode,
                 where: r.email == "five-controller@example.com"
               ),
               :count
             ) == 5
    end

    test "sixth request for the same email in an hour returns 429 with Retry-After", %{conn: conn} do
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{
        email: "over-controller@example.com",
        name: "Over",
        role: :member
      })
      |> Repo.insert!()

      for _ <- 1..5 do
        post(conn, "/api/auth/email-code/request", %{
          "email" => "over-controller@example.com"
        })
      end

      conn =
        post(conn, "/api/auth/email-code/request", %{
          "email" => "over-controller@example.com"
        })

      assert conn.status == 429

      retry_after = Plug.Conn.get_resp_header(conn, "retry-after") |> hd()
      assert is_binary(retry_after)
      {seconds, ""} = Integer.parse(retry_after)
      assert seconds > 0
      assert seconds <= 3600
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 2 — Verification and Lockout (issue #31 task 2.3)
  # ---------------------------------------------------------------------------
  #
  # Coverage (`specs/email-code-authentication/spec.md` §"Atomic Single-Use
  # Code Verification" + §"Failed-Verification Lockout", `design.md`
  # §"Interfaces / Contracts"):
  #
  #   * `POST /api/auth/email-code/verify` accepts `{email, code}` with
  #     optional Bearer. A valid code without a bearer returns 200.
  #   * An invalid bearer returns 401 immediately.
  #   * A wrong code returns 401 (single attempt, not yet at lockout).
  #   * A User-B bearer for User-A's code returns 401.
  #   * After 10 failures, the 11th attempt returns 429 with Retry-After.
  #
  # RED-phase note: each test references
  # `MealPlannerApiWeb.EmailCodeAuthController.verify/2` and
  # `MealPlannerApiWeb.Plugs.OptionalBearerUser`, neither of which exist yet.
  describe "POST /api/auth/email-code/verify" do
    # Phase 4 task 4.2 — User with NO `:active` memberships renders the
    # `:none` outcome: a `200` with a JWT that intentionally OMITS
    # `membership_id` so `LoadCurrentMembership` halts with
    # `401 membership_id_required` and routes the client to invite
    # acceptance (spec §"Verify Response Outcomes by Active-Membership
    # Count"). The legacy `body["status"] == "verified"` placeholder
    # was retired in Phase 4 GREEN.
    test "valid code with no bearer (zero-membership user) returns 200, mints an access_v2 JWT without membership_id, and consumes the row",
         %{conn: conn} do
      user = insert_user!("verify-ok@example.com", "Verify OK")
      code = "123456"
      insert_verification_code!(user, code)

      conn =
        post(conn, "/api/auth/email-code/verify", %{
          "email" => user.email,
          "code" => code
        })

      assert conn.status == 200
      body = json_response(conn, 200)

      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      # `:none` outcome has no membership-scoped fields.
      refute Map.has_key?(body, "membership")
      refute Map.has_key?(body, "account")

      {:ok, claims} = Guardian.decode_and_verify(body["access_token"])
      assert claims["typ"] == "access_v2"
      assert claims["user_id"] == Ecto.UUID.cast!(user.id)

      refute Map.has_key?(claims, "membership_id"),
             "no-membership JWT MUST omit membership_id so LoadCurrentMembership halts with 401 membership_id_required"

      [row] =
        Repo.all(from(r in EmailVerificationCode, where: r.user_id == ^user.id))

      refute is_nil(row.consumed_at)
    end

    test "invalid bearer returns 401 immediately", %{conn: conn} do
      user = insert_user!("verify-bad-bearer@example.com", "Bad Bearer")
      code = "123456"
      insert_verification_code!(user, code)

      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-jwt-token")
        |> post("/api/auth/email-code/verify", %{
          "email" => user.email,
          "code" => code
        })

      assert conn.status == 401

      [row] =
        Repo.all(from(r in EmailVerificationCode, where: r.user_id == ^user.id))

      assert is_nil(row.consumed_at)
    end

    test "wrong code returns 401 and does not consume the row", %{conn: conn} do
      user = insert_user!("verify-wrong-ctrl@example.com", "Wrong")
      code = "123456"
      insert_verification_code!(user, code)

      conn =
        post(conn, "/api/auth/email-code/verify", %{
          "email" => user.email,
          "code" => "000000"
        })

      assert conn.status == 401

      [row] =
        Repo.all(from(r in EmailVerificationCode, where: r.user_id == ^user.id))

      assert is_nil(row.consumed_at)
    end

    test "User-B bearer for User-A's code returns 401 and does not consume", %{conn: conn} do
      user_a = insert_user!("verify-a-ctrl@example.com", "A Ctrl")
      user_b = insert_user!("verify-b-ctrl@example.com", "B Ctrl")

      code = "123456"
      insert_verification_code!(user_a, code)

      {:ok, jwt, _claims} =
        MealPlannerApi.Auth.Guardian.encode_and_sign(
          user_b,
          %{"sub" => user_b.id},
          token_type: "access"
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> jwt)
        |> post("/api/auth/email-code/verify", %{
          "email" => user_a.email,
          "code" => code
        })

      assert conn.status == 401

      [row] =
        Repo.all(from(r in EmailVerificationCode, where: r.user_id == ^user_a.id))

      assert is_nil(row.consumed_at)
    end

    test "eleventh attempt returns 429 with Retry-After", %{conn: conn} do
      user = insert_user!("verify-lockout-ctrl@example.com", "Lockout Ctrl")
      code = "123456"
      insert_verification_code!(user, code)

      for _ <- 1..10 do
        post(conn, "/api/auth/email-code/verify", %{
          "email" => user.email,
          "code" => "000000"
        })
      end

      conn =
        post(conn, "/api/auth/email-code/verify", %{
          "email" => user.email,
          "code" => code
        })

      assert conn.status == 429

      retry_after = Plug.Conn.get_resp_header(conn, "retry-after") |> hd()
      assert is_binary(retry_after)
      {seconds, ""} = Integer.parse(retry_after)
      assert seconds > 0
      assert seconds <= 3600

      [row] =
        Repo.all(from(r in EmailVerificationCode, where: r.user_id == ^user.id))

      assert is_nil(row.consumed_at)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 4 task 4.2 — Verify response shape per outcome kind
  # (`specs/email-code-authentication/spec.md` §"Verify Response Outcomes
  # by Active-Membership Count" + §"Selection Continuation Security").
  # ---------------------------------------------------------------------------
  #
  # The service already branches 0/1/N — Phase 4 just teaches the
  # controller to translate each branch into the right HTTP payload:
  #
  #   * `:single`   → `200 {access_token, refresh_token, user, account,
  #                          membership, subscription, websocket}`
  #                   (the canonical auth payload used by
  #                   `AuthController.password/2` etc.).
  #   * `:none`     → `200 {access_token, refresh_token, user}` — no
  #                   membership, no account; JWT `membership_id` is
  #                   absent so the client routes to invite acceptance.
  #   * `:multiple` → `200 {memberships: [...], continuation_token}` —
  #                   no JWT, the client exchanges the continuation at
  #                   `/api/auth/switch-account`.
  #
  # RED-phase note: these tests assert response shapes the controller
  # does NOT yet render (it still returns the Phase 2 placeholder).
  describe "POST /api/auth/email-code/verify outcome rendering (Phase 4 task 4.2)" do
    setup do
      # Force `access_v2` issuance for the JWT-minting outcomes —
      # without this, `AccountsMembership.claims_for/2` still returns
      # the v2 shape, but `EmailCodeAuth.exchange_continuation/3` (and
      # therefore the controller's `:single` branch) would mint
      # legacy `access` tokens via `Accounts.claims_for/2`.
      previous = Application.get_env(:meal_planner_api, :tenancy_v2_only)
      Application.put_env(:meal_planner_api, :tenancy_v2_only, true)
      on_exit(fn -> Application.put_env(:meal_planner_api, :tenancy_v2_only, previous) end)
      :ok
    end

    test "single active membership returns 200 with access_token + membership payload", %{
      conn: conn
    } do
      user = insert_user_with_membership!("verify_single_ctrl@example.com", :owner)
      code = "111111"
      insert_verification_code!(user, code)

      conn =
        post(conn, "/api/auth/email-code/verify", %{
          "email" => user.email,
          "code" => code
        })

      body = json_response(conn, 200)

      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert body["token_type"] == "Bearer"
      assert is_map(body["user"])
      assert is_map(body["account"])
      assert is_map(body["membership"])
      assert body["membership"]["account_id"] == to_string(user.membership.account_id)
      assert body["account"]["id"] == to_string(user.membership.account_id)

      refute Map.has_key?(body, "continuation_token"),
             "single outcome must NOT return a continuation_token"

      {:ok, claims} = Guardian.decode_and_verify(body["access_token"])
      assert claims["typ"] == "access_v2"
      assert claims["membership_id"] == Ecto.UUID.cast!(user.membership.id)
      assert claims["account_id"] == Ecto.UUID.cast!(user.membership.account_id)
      assert claims["user_id"] == Ecto.UUID.cast!(user.id)

      # The row is consumed exactly once.
      [row] = Repo.all(from(r in EmailVerificationCode, where: r.user_id == ^user.id))
      refute is_nil(row.consumed_at)
    end

    test "multiple active memberships returns 200 with summaries and continuation_token, no JWT",
         %{conn: conn} do
      user = insert_user_with_two_memberships!("verify_multi_ctrl@example.com")
      code = "333333"
      insert_verification_code!(user, code)

      conn =
        post(conn, "/api/auth/email-code/verify", %{
          "email" => user.email,
          "code" => code
        })

      body = json_response(conn, 200)

      assert is_list(body["memberships"])
      assert length(body["memberships"]) == 2

      summary_keys = ~w(membership_id account_id role plan subscription_status)

      for summary <- body["memberships"] do
        for key <- summary_keys do
          assert Map.has_key?(summary, key), "summary missing key #{key}"
        end
      end

      assert is_binary(body["continuation_token"])
      assert byte_size(body["continuation_token"]) > 20

      # Multi-membership must NOT mint an access_v2 — the client must
      # exchange the continuation at `/api/auth/switch-account` first.
      refute Map.has_key?(body, "access_token")
      refute Map.has_key?(body, "refresh_token")

      refute Map.has_key?(body, "membership"),
             "multi-membership response must NOT carry a single membership payload"

      [row] = Repo.all(from(r in EmailVerificationCode, where: r.user_id == ^user.id))
      refute is_nil(row.consumed_at)
    end
  end

  # ---- Phase 2 helpers --------------------------------------------------------

  defp insert_user!(email, name) do
    %PersistenceUser{}
    |> PersistenceUser.changeset(%{email: email, name: name, role: :member})
    |> Repo.insert!()
  end

  defp insert_verification_code!(user, code) do
    %EmailVerificationCode{}
    |> Ecto.Changeset.change(%{
      user_id: user.id,
      email: user.email,
      code_hash: MealPlannerApi.Services.EmailCodeAuth.hash_code(code),
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    })
    |> Repo.insert!()
  end

  # ---- Phase 4 helpers --------------------------------------------------------
  #
  # Local copies of the Phase 3 service-test helpers. Kept in this file
  # so the controller test can build the fixtures it needs without
  # importing test-private helpers from a sibling module.
  #
  # `insert_user_with_membership!/2` returns the User pinned to its
  # single `.membership` for ergonomic assertion.
  #
  # `insert_user_with_two_memberships!/1` returns the User with
  # `.memberships` preloaded (`:account`) for the `:multiple` outcome.
  defp insert_user_with_membership!(email, role) do
    user =
      user_with_memberships(
        %{email: email, name: "M #{email}"},
        [
          {%{plan: :individual, name: "Solo #{email}"}, role}
        ]
      )

    [membership] = user.memberships
    Map.put(user, :membership, membership)
  end

  defp insert_user_with_two_memberships!(email) do
    user_with_memberships(
      %{email: email, name: "Multi #{email}"},
      [
        {%{plan: :individual, name: "Solo #{email}"}, :owner},
        {%{plan: :family_4, name: "Family #{email}"}, :owner}
      ]
    )
  end
end
