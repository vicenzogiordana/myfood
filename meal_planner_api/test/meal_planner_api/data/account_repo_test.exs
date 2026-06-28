defmodule MealPlannerApi.Data.AccountRepoTest do
  @moduledoc """
  Tests for `MealPlannerApi.Data.AccountRepo` — Phase A — Tenancy
  Refactor, PR 2b task 2.12.

  Coverage:

    * `get_account_with_users!/1` preloads `memberships: :user` (deviation
      #2 from PR 1, carried over).
    * `list_active_memberships_for_account/1` returns only `:active`
      memberships for the given account (PR 2b helper).
    * Multi-familia isolation: a User with memberships in two accounts
      surfaces the correct memberships for each account lookup.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Data.AccountRepo
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "get_account_with_users!/1 (PR 1 deviation #2 — preloads memberships: :user)" do
    test "returns the Account with its active memberships and preloaded :user on each membership" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Preload Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      owner =
        insert_user_with_active_membership(account.id, "preload-owner@example.com", :owner)

      _member =
        insert_user_with_active_membership(account.id, "preload-member@example.com", :member)

      loaded = AccountRepo.get_account_with_users!(account.id)

      assert loaded.id == account.id

      active_memberships = Enum.filter(loaded.memberships, &(&1.status == :active))
      assert length(active_memberships) == 2

      owner_membership = Enum.find(active_memberships, &(&1.user_id == owner.id))
      assert Ecto.assoc_loaded?(owner_membership.user)
      assert owner_membership.user.email == "preload-owner@example.com"
    end

    test "raises Ecto.NoResultsError when the Account doesn't exist" do
      assert_raise Ecto.NoResultsError, fn ->
        AccountRepo.get_account_with_users!(Ecto.UUID.generate())
      end
    end
  end

  describe "list_active_memberships_for_account/1 (PR 2b task 2.12 helper)" do
    test "returns only :active memberships for the given account" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Active List Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      owner =
        insert_user_with_active_membership(account.id, "active-owner@example.com", :owner)

      member =
        insert_user_with_active_membership(account.id, "active-member@example.com", :member)

      # Insert an :invited row that MUST NOT appear in the active list.
      insert_invitee(account.id, "invited@example.com")

      active = AccountRepo.list_active_memberships_for_account(account.id)

      assert length(active) == 2
      emails = Enum.map(active, & &1.user.email) |> Enum.sort()
      assert emails == Enum.sort(["active-owner@example.com", "active-member@example.com"])
      assert Enum.all?(active, &(&1.status == :active))

      # Sanity: the owner and member are both in the result.
      assert Enum.any?(active, &(&1.user_id == owner.id))
      assert Enum.any?(active, &(&1.user_id == member.id))
    end

    test "returns [] for an account with no active memberships" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Empty Account",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      assert AccountRepo.list_active_memberships_for_account(account.id) == []
    end

    test "does NOT include memberships from a different account (multi-familia isolation)" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account_a} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Family A",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, account_b} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Family B",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      _owner_a =
        insert_user_with_active_membership(account_a.id, "user-a@example.com", :owner)

      _owner_b =
        insert_user_with_active_membership(account_b.id, "user-b@example.com", :owner)

      list_a = AccountRepo.list_active_memberships_for_account(account_a.id)
      list_b = AccountRepo.list_active_memberships_for_account(account_b.id)

      assert length(list_a) == 1
      assert hd(list_a).user.email == "user-a@example.com"

      assert length(list_b) == 1
      assert hd(list_b).user.email == "user-b@example.com"
    end
  end

  describe "multi-familia User — a User with two memberships is correctly scoped per account" do
    test "the same User appears in both account lookups when they have two :active memberships" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, personal} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Personal Account",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, family} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Family Account",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      multi_user =
        insert_user_with_active_membership(personal.id, "multi@example.com", :owner)

      _family_membership =
        insert_user_with_active_membership_for_user(
          family.id,
          multi_user,
          "multi@example.com",
          :member
        )

      personal_list = AccountRepo.list_active_memberships_for_account(personal.id)
      family_list = AccountRepo.list_active_memberships_for_account(family.id)

      assert length(personal_list) == 1
      assert hd(personal_list).user_id == multi_user.id
      assert hd(personal_list).role == :owner
      assert hd(personal_list).account_id == personal.id

      assert length(family_list) == 1
      assert hd(family_list).user_id == multi_user.id
      assert hd(family_list).role == :member
      assert hd(family_list).account_id == family.id
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp insert_user_with_active_membership(account_id, email, role) do
    user =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: email, role: role})
      |> Repo.insert!()

    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account_id,
      user_id: user.id,
      role: role,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    user
  end

  defp insert_user_with_active_membership_for_user(account_id, user, _email, role) do
    membership =
      %AccountMembership{}
      |> AccountMembership.changeset(%{
        account_id: account_id,
        user_id: user.id,
        role: role,
        status: :active,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    membership
  end

  defp insert_invitee(account_id, email) do
    user =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: email, role: :member})
      |> Repo.insert!()

    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account_id,
      user_id: user.id,
      role: :member,
      status: :invited
    })
    |> Repo.insert!()

    user
  end
end
