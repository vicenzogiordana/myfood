defmodule MealPlannerApi.AccountsRegistrationTest do
  @moduledoc """
  Tests for `MealPlannerApi.Accounts.register_with_password/1` — Phase A
  Tenancy Refactor, PR 2b task 2.10.

  Pre-Phase A, `register_with_password/1` created an `Account` and a
  `User` in a single `Multi` but **did not insert an `AccountMembership`
  row**. The PR 2b atomic-registration fix creates the
  `:owner :active` membership in the same transaction so that:

    * Fresh registrations are immediately addressable by the new
      `current_membership`-based controller/channel paths in PR 3.
    * The `AccountService.me/1` fallback path is no longer exercised by
      fresh users — it stays only for legacy rows that pre-date the
      backfill migration.

  Coverage:

    * Successful registration yields exactly one `:owner :active`
      `AccountMembership` row whose `account_id` and `user_id` match
      the inserted Account/User.
    * A forced failure (duplicate email) rolls back the entire
      transaction — no orphan Account, no orphan User, no orphan
      Membership.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Repo

  import Ecto.Query

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "register_with_password/1 — atomic registration" do
    test "successful registration yields exactly one :owner :active membership row" do
      email = "atomic-owner@example.com"

      assert {:ok, %{user: user, account: account}} =
               Accounts.register_with_password(%{
                 "email" => email,
                 "password" => "super_secret_123",
                 "name" => "Atomic Owner"
               })

      # The new contract: an :owner :active AccountMembership row exists
      # pointing at the just-created Account and User.
      memberships =
        Repo.all(
          from(m in AccountMembership,
            where: m.user_id == ^user.id and m.account_id == ^account.id
          )
        )

      assert length(memberships) == 1,
             "expected exactly one membership row, got #{length(memberships)}"

      [membership] = memberships
      assert membership.role == :owner
      assert membership.status == :active
      assert %DateTime{} = membership.joined_at
      assert membership.account_id == account.id
      assert membership.user_id == user.id
    end

    test "User row is linked to the Account row (account_id is set)" do
      assert {:ok, %{user: user, account: account}} =
               Accounts.register_with_password(%{
                 "email" => "linked-user@example.com",
                 "password" => "super_secret_123",
                 "name" => "Linked User"
               })

      assert user.account_id == account.id
    end

    test "Account has exactly one :owner after registration" do
      assert {:ok, %{user: _user, account: account}} =
               Accounts.register_with_password(%{
                 "email" => "sole-owner@example.com",
                 "password" => "super_secret_123",
                 "name" => "Sole Owner"
               })

      owners =
        Repo.all(
          from(m in AccountMembership,
            where: m.account_id == ^account.id and m.role == :owner
          )
        )

      assert length(owners) == 1
      assert hd(owners).status == :active
    end

    test "a duplicate-email registration rolls back the Account and the User" do
      email = "rollback@example.com"

      assert {:ok, %{user: first_user, account: first_account}} =
               Accounts.register_with_password(%{
                 "email" => email,
                 "password" => "super_secret_123",
                 "name" => "First Try"
               })

      # Second registration with the same email MUST fail and roll back.
      assert {:error, :email_already_registered} =
               Accounts.register_with_password(%{
                 "email" => email,
                 "password" => "different_password",
                 "name" => "Second Try"
               })

      # The DB should look like after only the first registration.
      all_users = Repo.all(from(u in PersistenceUser))
      all_accounts = Repo.all(from(a in PersistenceAccount))
      all_memberships = Repo.all(AccountMembership)

      assert length(all_users) == 1
      assert hd(all_users).id == first_user.id
      assert length(all_accounts) == 1
      assert hd(all_accounts).id == first_account.id
      assert length(all_memberships) == 1
    end

    test "membership is queryable by account_id immediately after registration" do
      assert {:ok, %{account: account}} =
               Accounts.register_with_password(%{
                 "email" => "query-by-acct@example.com",
                 "password" => "super_secret_123",
                 "name" => "Query Owner"
               })

      # This mirrors what AccountService.me/1 does: walk memberships and
      # pick the first :active one. It MUST succeed without falling back
      # to a User-by-id lookup.
      rows =
        Repo.all(
          from(m in AccountMembership,
            where: m.account_id == ^account.id and m.status == :active
          )
        )

      assert length(rows) == 1
      assert hd(rows).role == :owner
    end
  end
end
