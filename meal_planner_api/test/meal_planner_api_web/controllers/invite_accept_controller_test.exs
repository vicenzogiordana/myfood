defmodule MealPlannerApiWeb.InviteAcceptControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.InviteService

  describe "POST /api/invites/:token/accept (task 3.4)" do
    test "existing User accepts and receives a fresh auth payload", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_accept_a@example.com"}, [
          {%{plan: :family_4, name: "Family Accept A"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      invitee =
        user_with_memberships(%{email: "invitee_existing@example.com"}, [
          {%{plan: :individual, name: "Invitee Own Account"}, :owner}
        ])

      [invitee_own_membership] = invitee.memberships
      invitee_token = issue_access_v2_token(invitee, invitee_own_membership)

      {:ok, %{token: plaintext}} =
        AccountsMembership.invite(account, owner_membership, "invitee_existing@example.com")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> invitee_token)
        |> post("/api/invites/#{plaintext}/accept", %{})

      body = json_response(conn, 200)

      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert body["membership"]["account_id"] == account.id
      assert body["membership"]["status"] == "active"
      assert body["account"]["id"] == account.id
    end

    test "new User accepts, creating the User row", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_accept_b@example.com"}, [
          {%{plan: :family_4, name: "Family Accept B"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      {:ok, %{token: plaintext}} =
        AccountsMembership.invite(account, owner_membership, "brand_new@example.com")

      conn =
        post(conn, "/api/invites/#{plaintext}/accept", %{
          "name" => "Brand New",
          "password" => "supersecret123"
        })

      body = json_response(conn, 200)

      assert body["user"]["email"] == "brand_new@example.com"
      assert body["membership"]["status"] == "active"

      new_user =
        Repo.get_by(MealPlannerApi.Persistence.Accounts.User, email: "brand_new@example.com")

      assert new_user.name == "Brand New"
      assert is_binary(new_user.password_hash)
    end

    test "replaying an already-accepted token returns 410 invite_token_used", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_accept_c@example.com"}, [
          {%{plan: :family_4, name: "Family Accept C"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      {:ok, %{token: plaintext}} =
        AccountsMembership.invite(account, owner_membership, "replay@example.com")

      _first =
        post(conn, "/api/invites/#{plaintext}/accept", %{
          "name" => "Replay User",
          "password" => "supersecret123"
        })

      conn =
        post(conn, "/api/invites/#{plaintext}/accept", %{
          "name" => "Replay User",
          "password" => "supersecret123"
        })

      assert json_response(conn, 410)["error"] == "invite_token_used"
    end

    test "an expired token returns 410 invite_token_expired", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_accept_d@example.com"}, [
          {%{plan: :family_4, name: "Family Accept D"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      {:ok, %{token: plaintext, membership_id: membership_id}} =
        AccountsMembership.invite(account, owner_membership, "expired@example.com")

      Repo.get!(AccountMembership, membership_id)
      |> AccountMembership.changeset(%{
        invite_expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
      })
      |> Repo.update!()

      conn =
        post(conn, "/api/invites/#{plaintext}/accept", %{
          "name" => "Expired User",
          "password" => "supersecret123"
        })

      assert json_response(conn, 410)["error"] == "invite_token_expired"
    end

    # Post-review fix pass, item 6: this route is deliberately OUTSIDE the
    # `:auth` pipeline (per its own moduledoc) — `resolve_invitee/2`'s own
    # Bearer-header handling is the ONLY thing preventing unauthenticated
    # access to the "existing User accepts" path. No test previously
    # exercised a request with no/invalid Authorization header and an
    # empty body.
    test "no Authorization header and an empty body returns 401 unauthorized", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_accept_noauth@example.com"}, [
          {%{plan: :family_4, name: "Family Accept NoAuth"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      {:ok, %{token: plaintext}} =
        AccountsMembership.invite(account, owner_membership, "noauth@example.com")

      conn = post(conn, "/api/invites/#{plaintext}/accept", %{})

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "an invalid (malformed) Authorization header and an empty body returns 401 unauthorized",
         %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_accept_badauth@example.com"}, [
          {%{plan: :family_4, name: "Family Accept BadAuth"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      {:ok, %{token: plaintext}} =
        AccountsMembership.invite(account, owner_membership, "badauth@example.com")

      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> post("/api/invites/#{plaintext}/accept", %{})

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    # Post-review fix pass, item 7: `error_status/1`'s `invite_token_unknown`
    # mapping (404) had zero HTTP-level test coverage.
    test "an unknown/bogus token returns 404 invite_token_unknown", %{conn: conn} do
      conn =
        post(conn, "/api/invites/#{Ecto.UUID.generate()}/accept", %{
          "name" => "Nobody",
          "password" => "supersecret123"
        })

      assert json_response(conn, 404)["error"] == "invite_token_unknown"
    end
  end

  # Post-review fix pass, item 8 (security): Guardian's `token_type:`
  # option is never actually checked by Guardian at decode time — without
  # an explicit `claims["typ"] in ["access", "access_v2"]` assertion in
  # `resolve_invitee/2`, a `refresh` token presented as a Bearer header
  # would authenticate the "existing User accepts" path.
  describe "Bearer token typ validation (post-review fix, item 8)" do
    test "a refresh token used as Bearer is treated as unauthenticated", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_accept_reftyp@example.com"}, [
          {%{plan: :family_4, name: "Family Accept RefTyp"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      register_body =
        conn
        |> post("/api/auth/password", %{
          "mode" => "register",
          "email" => "invitee_reftyp@example.com",
          "password" => "supersecret123",
          "name" => "Invitee RefTyp"
        })
        |> json_response(200)

      refresh_token = register_body["refresh_token"]

      {:ok, refresh_claims} =
        Guardian.decode_and_verify(refresh_token, %{}, token_type: "refresh")

      assert refresh_claims["typ"] == "refresh"

      {:ok, %{token: plaintext}} =
        AccountsMembership.invite(account, owner_membership, "invitee_reftyp@example.com")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> refresh_token)
        |> post("/api/invites/#{plaintext}/accept", %{})

      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end

  # Post-review fix pass, item 2: `accept_invite/2` must consult the same
  # `MEAL_PLANNER_TENANCY_V2` flag `auth_controller.ex` uses, instead of
  # unconditionally minting `access_v2` regardless of the flag.
  describe "tenancy_v2_only flag (post-review fix)" do
    setup do
      previous = Application.get_env(:meal_planner_api, :tenancy_v2_only)

      on_exit(fn ->
        Application.put_env(:meal_planner_api, :tenancy_v2_only, previous)
      end)

      :ok
    end

    test "new User accept mints access (not access_v2) when the flag is off", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_accept_flagoff@example.com"}, [
          {%{plan: :family_4, name: "Family Accept FlagOff"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      {:ok, %{token: plaintext}} =
        AccountsMembership.invite(account, owner_membership, "flagoff_new@example.com")

      Application.put_env(:meal_planner_api, :tenancy_v2_only, false)

      body =
        conn
        |> post("/api/invites/#{plaintext}/accept", %{
          "name" => "Flag Off New",
          "password" => "supersecret123"
        })
        |> json_response(200)

      {:ok, claims} = Guardian.decode_and_verify(body["access_token"])

      assert claims["typ"] == "access"
      refute Map.has_key?(claims, "membership_id")
    end
  end

  # Second post-review fix pass: `accept/2`'s generic `{:error, reason} ->
  # ... Atom.to_string(reason)` clause assumes `reason` is always an atom.
  # `accept_invite_with_lookup/2`'s `Repo.update/1` call can propagate
  # `{:error, %Ecto.Changeset{}}` from the
  # `account_memberships_active_account_user_unique_index` partial unique
  # constraint when two DIFFERENT `:invited` rows exist for the same
  # `(account_id, user_id)` pair and the second one is accepted after the
  # first already flipped to `:active` (a retried/duplicate invite, or a
  # concurrent accept race — `AccountsMembership.invite/3`'s app-layer
  # `:already_invited` guard only stops a SECOND invite call; it does not
  # stop a SECOND accept of two invites that were already both minted).
  # `Atom.to_string/1` on a `%Ecto.Changeset{}` raises `ArgumentError`,
  # turning a controlled 409 into an unhandled 500.
  describe "changeset-level unique-constraint conflict on accept (second post-review fix pass)" do
    test "accepting a second invite for a user already active on the account returns 409, not a crash",
         %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_accept_dupe@example.com"}, [
          {%{plan: :family_4, name: "Family Accept Dupe"}, :owner}
        ])

      [owner_membership] = owner.memberships

      # Two independent :invited rows for the SAME email/user on the SAME
      # account, created directly via InviteService (bypassing
      # AccountsMembership.invite/3's :already_invited app-layer guard) —
      # this is the only way to reach the changeset-level constraint
      # instead of the earlier app-layer check.
      {:ok, %{token: first_plaintext}} =
        InviteService.create_invite_row(owner_membership, "dupe_invitee@example.com")

      {:ok, %{token: second_plaintext}} =
        InviteService.create_invite_row(owner_membership, "dupe_invitee@example.com")

      first_conn =
        post(conn, "/api/invites/#{first_plaintext}/accept", %{
          "name" => "Dupe Invitee",
          "password" => "supersecret123"
        })

      assert json_response(first_conn, 200)

      second_conn =
        post(conn, "/api/invites/#{second_plaintext}/accept", %{
          "name" => "Dupe Invitee",
          "password" => "supersecret123"
        })

      assert json_response(second_conn, 409)["error"] == "already_a_member"
    end
  end
end
