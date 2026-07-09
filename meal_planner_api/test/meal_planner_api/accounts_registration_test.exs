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
  alias Ecto.Multi
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

    test "the result map exposes the :owner :active membership directly (PR 3a task 3.8)" do
      # auth_controller.ex's password/2 needs the membership to mint an
      # access_v2 JWT without an extra query — mirrors the shape
      # authenticate_with_password/1 already returns.
      assert {:ok, %{user: user, account: account, membership: membership}} =
               Accounts.register_with_password(%{
                 "email" => "exposed-membership@example.com",
                 "password" => "super_secret_123",
                 "name" => "Exposed Membership"
               })

      assert %AccountMembership{} = membership
      assert membership.user_id == user.id
      assert membership.account_id == account.id
      assert membership.role == :owner
      assert membership.status == :active
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

  # ----------------------------------------------------------------------
  # PR 2b post-review fix pass — item 4: prove the Ecto.Multi itself rolls
  # back Account + User when the :membership step fails.
  # ----------------------------------------------------------------------
  #
  # The `create_account_and_user/5` private helper inside
  # `Accounts.register_with_password/1` can't have its `:membership`
  # step failure triggered from the public API — both `account.id` and
  # `user.id` are freshly Ecto-generated inside the same Multi, so the
  # `unique_constraint([:account_id, :user_id])` never actually fires
  # from outside. Instead, this test builds an equivalent 3-step
  # `Ecto.Multi` (same shape: insert :account, then :user, then
  # :membership) with an intentionally invalid membership changeset
  # (`role: :not_a_real_role`, rejected by
  # `AccountMembership.changeset/2`'s `validate_inclusion(:role, ...)`)
  # and runs it directly via `Repo.transaction/1`. This is a legitimate
  # way to test Ecto.Multi/Repo.transaction rollback semantics without
  # adding a test-only injection seam to the real function.
  describe "Ecto.Multi rollback semantics (equivalent 3-step Multi)" do
    test ":account and :user are rolled back when the :membership step fails" do
      email = "multi-rollback@example.com"
      name = "Multi Rollback"

      {:ok, subscription_plan_id} = MealPlannerApi.Subscriptions.ensure_default_plan_id(:individual)

      account_attrs = %{
        name: name,
        plan: :individual,
        default_budget_cents: 0,
        subscription_plan_id: subscription_plan_id
      }

      user_attrs = %{
        email: email,
        name: name,
        role: :owner,
        password_hash: "irrelevant-hash"
      }

      transaction =
        Multi.new()
        |> Multi.insert(
          :account,
          PersistenceAccount.changeset(%PersistenceAccount{}, account_attrs)
        )
        |> Multi.insert(:user, fn %{account: account} ->
          attrs = Map.put(user_attrs, :account_id, account.id)
          PersistenceUser.changeset(%PersistenceUser{}, attrs)
        end)
        |> Multi.insert(:membership, fn %{account: account, user: user} ->
          # Intentionally invalid — rejected by
          # validate_inclusion(:role, [:owner, :member]).
          %AccountMembership{}
          |> AccountMembership.changeset(%{
            account_id: account.id,
            user_id: user.id,
            role: :not_a_real_role,
            status: :active,
            joined_at: DateTime.utc_now()
          })
        end)

      assert {:error, :membership, changeset, _changes} = Repo.transaction(transaction)
      refute changeset.valid?
      assert {"is invalid", _opts} = Keyword.get(changeset.errors, :role)

      # The whole transaction — including :account and :user — rolled back.
      assert Repo.get_by(PersistenceUser, email: email) == nil
      assert Repo.get_by(PersistenceAccount, name: name) == nil
      assert Repo.all(AccountMembership) == []
    end
  end
end
