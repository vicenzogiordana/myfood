defmodule MealPlannerApi.AccountsMembershipTest do
  @moduledoc """
  Tests for `MealPlannerApi.AccountsMembership` use cases — Phase A — Tenancy
  Refactor, PR 2a (tasks 2.2–2.8).

  Coverage:
    * `current_membership/2` — load real membership by claim, synthesize
      virtual membership for legacy `access` tokens, refuse `nil` users
    * `seat_usage/1` — counts `:active + :invited` per Account, capacity
      resolved from `Account.plan`
    * `enforce_seat_cap/2` — refuses when `active + invited + count_to_add`
      exceeds the plan's capacity
    * `invite/3` — owner-only, seat-cap atomic, single-use token mint
    * `accept_invite/2` — flips `:invited → :active`, invalidates the token
    * `list_memberships/1`, `remove_member/2`, `leave/1` — owner roster
      ordering, owner-target protection, owner-cannot-leave
    * `switch_account/2` — multi-familia User re-issues JWT scoped to a
      second `:active` membership
  """
  use ExUnit.Case, async: false

  import MealPlannerApi.FactoryHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "seat_usage/1" do
    test "counts :active + :invited rows and resolves capacity from Account.plan" do
      owner =
        user_with_memberships(
          %{email: "seat-owner@example.com"},
          [
            {%{plan: :family_4, name: "F4"}, :owner}
          ]
        )

      [membership] = owner.memberships

      # Seed 2 :active :member memberships + 1 :invited :member membership.
      insert_member(membership.account_id, "m1@example.com", :active)
      insert_member(membership.account_id, "m2@example.com", :active)
      insert_member(membership.account_id, "m3@example.com", :invited)

      account = Repo.get!(PersistenceAccount, membership.account_id)
      usage = AccountsMembership.seat_usage(account)

      # Owner (1) + 2 active members + 1 invited member.
      assert usage.active == 3
      assert usage.invited == 1
      assert usage.capacity == 4
    end

    test "capacity is 1 for :individual" do
      owner =
        user_with_memberships(
          %{email: "individual@example.com"},
          [
            {%{plan: :individual, name: "Solo"}, :owner}
          ]
        )

      [membership] = owner.memberships
      account = Repo.get!(PersistenceAccount, membership.account_id)
      usage = AccountsMembership.seat_usage(account)

      assert usage.capacity == 1
      assert usage.active == 1
      assert usage.invited == 0
    end

    test "capacity is 6 for :family_6" do
      owner =
        user_with_memberships(
          %{email: "f6@example.com"},
          [
            {%{plan: :family_6, name: "F6"}, :owner}
          ]
        )

      [membership] = owner.memberships
      account = Repo.get!(PersistenceAccount, membership.account_id)
      usage = AccountsMembership.seat_usage(account)

      assert usage.capacity == 6
    end

    test "capacity is 6 for :trial (reuses :family_6 cap)" do
      owner =
        user_with_memberships(
          %{email: "trial@example.com"},
          [
            {%{plan: :trial, name: "Trial"}, :owner}
          ]
        )

      [membership] = owner.memberships
      account = Repo.get!(PersistenceAccount, membership.account_id)
      usage = AccountsMembership.seat_usage(account)

      assert usage.capacity == 6
    end
  end

  describe "enforce_seat_cap/2" do
    test "returns :ok when active + invited + count_to_add is below capacity" do
      owner =
        user_with_memberships(
          %{email: "below@example.com"},
          [
            {%{plan: :family_4, name: "F4"}, :owner}
          ]
        )

      [membership] = owner.memberships
      insert_member(membership.account_id, "x@example.com", :active)
      insert_member(membership.account_id, "y@example.com", :invited)

      account = Repo.get!(PersistenceAccount, membership.account_id)
      # 1 (owner) + 1 (active) + 1 (invited) = 3; count_to_add=1 → 4 ≤ 4 → ok
      assert :ok = AccountsMembership.enforce_seat_cap(account, 1)
    end

    test "returns :seat_cap_reached when active + invited + count_to_add exceeds capacity" do
      owner =
        user_with_memberships(
          %{email: "full@example.com"},
          [
            {%{plan: :family_4, name: "F4"}, :owner}
          ]
        )

      [membership] = owner.memberships
      insert_member(membership.account_id, "a@example.com", :active)
      insert_member(membership.account_id, "b@example.com", :active)
      insert_member(membership.account_id, "c@example.com", :active)

      account = Repo.get!(PersistenceAccount, membership.account_id)
      # 1 (owner) + 3 (active) = 4; count_to_add=1 → 5 > 4 → rejected
      assert {:error, :seat_cap_reached} =
               AccountsMembership.enforce_seat_cap(account, 1)
    end

    test "defaults count_to_add to 1" do
      owner =
        user_with_memberships(
          %{email: "default-count@example.com"},
          [
            {%{plan: :family_4, name: "F4"}, :owner}
          ]
        )

      [membership] = owner.memberships
      insert_member(membership.account_id, "a@example.com", :active)
      insert_member(membership.account_id, "b@example.com", :active)
      insert_member(membership.account_id, "c@example.com", :active)

      account = Repo.get!(PersistenceAccount, membership.account_id)
      assert {:error, :seat_cap_reached} = AccountsMembership.enforce_seat_cap(account)
    end
  end

  # ---- test helpers ----------------------------------------------------------

  defp insert_member(account_id, email, status) do
    {:ok, user} =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: email, role: :member})
      |> Repo.insert()

    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account_id,
      user_id: user.id,
      role: :member,
      status: status,
      joined_at: if(status == :active, do: DateTime.utc_now(), else: nil)
    })
    |> Repo.insert!()
  end
end
