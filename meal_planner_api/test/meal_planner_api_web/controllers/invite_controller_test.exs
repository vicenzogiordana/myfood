defmodule MealPlannerApiWeb.InviteControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo

  describe "POST /api/accounts/:account_id/invites (task 3.3)" do
    test "owner invite returns 201 with a plaintext token", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_invite_a@example.com"}, [
          {%{plan: :family_4, name: "Family Invite A"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account
      token = issue_access_v2_token(owner, owner_membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/accounts/#{account.id}/invites", %{"email" => "ana@example.com"})

      body = json_response(conn, 201)

      assert is_binary(body["invite"]["token"])
      assert String.length(body["invite"]["token"]) >= 40
      assert body["invite"]["email"] == "ana@example.com"
      assert is_binary(body["invite"]["membership_id"])
      assert is_binary(body["invite"]["expires_at"])
    end

    test "non-owner invite returns 403 not_owner", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_invite_b@example.com"}, [
          {%{plan: :family_4, name: "Family Invite B"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      member_user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "member_invite_b@example.com",
          name: "Member Invite B",
          role: :member
        })
        |> Repo.insert!()

      member_membership =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: member_user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      token = issue_access_v2_token(member_user, member_membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/accounts/#{account.id}/invites", %{"email" => "someone@example.com"})

      assert json_response(conn, 403)["error"] == "not_owner"
    end

    test "fifth invite on a :family_4 Account returns 409 seat_cap_reached", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_invite_c@example.com"}, [
          {%{plan: :family_4, name: "Family Invite C"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account
      token = issue_access_v2_token(owner, owner_membership)

      for n <- 1..3 do
        member_user =
          %PersistenceUser{}
          |> PersistenceUser.changeset(%{
            email: "member_invite_c_#{n}@example.com",
            name: "Member Invite C #{n}",
            role: :member
          })
          |> Repo.insert!()

        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: member_user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()
      end

      # Account now has 4 :active memberships (owner + 3 members) — at cap.
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/accounts/#{account.id}/invites", %{"email" => "fifth@example.com"})

      assert json_response(conn, 409)["error"] == "seat_cap_reached"
    end
  end
end
