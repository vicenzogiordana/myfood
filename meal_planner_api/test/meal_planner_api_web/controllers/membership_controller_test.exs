defmodule MealPlannerApiWeb.MembershipControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo

  describe "GET /api/accounts/:account_id/memberships (task 3.1)" do
    test "an active member lists the roster ordered role ASC, joined_at ASC (owner first)", %{
      conn: conn
    } do
      owner =
        user_with_memberships(%{email: "owner_a@example.com"}, [
          {%{plan: :family_4, name: "Family A"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      member_user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "member_a@example.com",
          name: "Member A",
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

      token = issue_access_v2_token(owner, owner_membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/accounts/#{account.id}/memberships")

      body = json_response(conn, 200)
      memberships = body["memberships"]

      assert Enum.map(memberships, & &1["role"]) == ["owner", "member"]
      assert Enum.map(memberships, & &1["email"]) == ["owner_a@example.com", "member_a@example.com"]
      assert Enum.map(memberships, & &1["status"]) == ["active", "active"]
      assert Enum.all?(memberships, &Map.has_key?(&1, "joined_at"))
      assert Enum.all?(memberships, &Map.has_key?(&1, "user_id"))
    end

    test "a dangling/unknown account reference returns 404 account_not_found (no existence leak)",
         %{conn: conn} do
      user = user_with_memberships(%{email: "dangling@example.com"}, [])
      bogus_account_id = Ecto.UUID.generate()

      # Legacy access_v1 claim shape (design §3.1) minted manually so the
      # `LoadCurrentMembership` plug synthesizes a virtual membership from
      # `account_id` without requiring a real AccountMembership row —
      # this is how EnforceAccountScope can pass (URL == claim account_id)
      # while the Account itself genuinely does not exist.
      claims = %{
        "account_id" => bogus_account_id,
        "account_type" => "individual",
        "subscription_tier" => "free",
        "email" => user.email,
        "name" => user.name
      }

      {:ok, token, _claims} = Guardian.encode_and_sign(user, claims, token_type: "access")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/accounts/#{bogus_account_id}/memberships")

      assert json_response(conn, 404)["error"] == "account_not_found"
    end

    test "cross-Account URL/JWT mismatch returns 403 account_mismatch", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_b@example.com"}, [
          {%{plan: :family_4, name: "Family B1"}, :owner},
          {%{plan: :individual, name: "Family B2"}, :owner}
        ])

      [membership_1, membership_2] = owner.memberships
      token = issue_access_v2_token(owner, membership_1)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/accounts/#{membership_2.account_id}/memberships")

      assert json_response(conn, 403)["error"] == "account_mismatch"
    end
  end

  describe "DELETE /api/accounts/:account_id/memberships/:user_id (task 3.2)" do
    test "owner removes a :member and the row is hard-deleted", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_c@example.com"}, [
          {%{plan: :family_4, name: "Family C"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      member_user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "member_c@example.com",
          name: "Member C",
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

      token = issue_access_v2_token(owner, owner_membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> delete("/api/accounts/#{account.id}/memberships/#{member_user.id}")

      assert response(conn, 204)
      refute Repo.get(AccountMembership, member_membership.id)
    end

    test "owner cannot remove themselves", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_d@example.com"}, [
          {%{plan: :family_4, name: "Family D"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account
      token = issue_access_v2_token(owner, owner_membership)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> delete("/api/accounts/#{account.id}/memberships/#{owner.id}")

      assert json_response(conn, 403)["error"] == "cannot_remove_owner"
      assert Repo.get(AccountMembership, owner_membership.id)
    end

    test "non-owner actor returns 403 not_owner", %{conn: conn} do
      owner =
        user_with_memberships(%{email: "owner_e@example.com"}, [
          {%{plan: :family_4, name: "Family E"}, :owner}
        ])

      [owner_membership] = owner.memberships
      account = owner_membership.account

      member_user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "member_e@example.com",
          name: "Member E",
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
        |> delete("/api/accounts/#{account.id}/memberships/#{owner.id}")

      assert json_response(conn, 403)["error"] == "not_owner"
      assert Repo.get(AccountMembership, member_membership.id)
    end
  end
end
