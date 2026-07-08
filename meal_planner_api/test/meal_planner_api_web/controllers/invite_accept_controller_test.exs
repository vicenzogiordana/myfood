defmodule MealPlannerApiWeb.InviteAcceptControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

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

      new_user = Repo.get_by(MealPlannerApi.Persistence.Accounts.User, email: "brand_new@example.com")
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
  end
end
