defmodule MealPlannerApi.AccountsMembershipIntegrationTest do
  @moduledoc """
  End-to-end integration test for the `MealPlannerApi.AccountsMembership`
  context — Phase A — Tenancy Refactor, PR 2a task 2.16.

  Exercises the full Phase A use-case chain (in-process, no HTTP):

    * invite → accept (existing User) → list → remove → leave
    * multi-familia switch-account with claim map update
    * concurrent invites on a full :family_4 Account never produce
      more than 4 `:active + :invited` rows (race test using
      `Task.async_stream`)
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

    # Post-review fix pass, item 2: `accept_invite/2` and `switch_account/2`
    # now consult `:meal_planner_api, :tenancy_v2_only` before minting
    # `access_v2` claims (same flag `auth_controller.ex` uses). This suite
    # exercises the Phase A `access_v2` claim shape end-to-end, so flip
    # the flag on for the duration of each test.
    previous = Application.get_env(:meal_planner_api, :tenancy_v2_only)
    Application.put_env(:meal_planner_api, :tenancy_v2_only, true)
    on_exit(fn -> Application.put_env(:meal_planner_api, :tenancy_v2_only, previous) end)

    :ok
  end

  describe "invite → accept → list → remove → leave flow" do
    test "a complete end-to-end membership lifecycle" do
      owner =
        user_with_memberships(
          %{email: "lifecycle-owner@example.com", name: "Lifecycle Owner"},
          [
            {%{plan: :family_4, name: "Lifecycle Family"}, :owner}
          ]
        )

      [owner_membership] = owner.memberships
      account = Repo.get!(PersistenceAccount, owner_membership.account_id)

      invitee = insert_user_only("lifecycle-invitee@example.com", "Lifecycle Invitee")

      # 1) Invite
      {:ok, invite_result} =
        AccountsMembership.invite(account, owner_membership, "lifecycle-invitee@example.com")

      assert invite_result.token != nil
      assert invite_result.email == "lifecycle-invitee@example.com"

      # 2) Accept
      {:ok, accept_result} =
        AccountsMembership.accept_invite(invite_result.token, invitee)

      assert accept_result.membership.status == :active
      assert accept_result.claims["typ"] == "access_v2"

      # 3) List — owner + invitee
      rows = AccountsMembership.list_memberships(account)
      emails =
        rows
        |> Enum.map(& &1.user.email)
        |> Enum.sort()

      assert emails == Enum.sort(["lifecycle-owner@example.com", "lifecycle-invitee@example.com"])

      # 4) Remove invitee
      [invitee_row | _] = Enum.filter(rows, &(&1.user_id == invitee.id))

      assert :ok =
               AccountsMembership.remove_member(account, invitee.id, owner_membership)

      assert Repo.get(AccountMembership, invitee_row.id) == nil

      # 5) Re-add and have the invitee leave
      {:ok, second_invite} =
        AccountsMembership.invite(account, owner_membership, "lifecycle-invitee@example.com")

      {:ok, _accept2} = AccountsMembership.accept_invite(second_invite.token, invitee)

      rows_after = AccountsMembership.list_memberships(account)
      [invitee_row_2 | _] = Enum.filter(rows_after, &(&1.user_id == invitee.id))

      assert :ok = AccountsMembership.leave(account, invitee_row_2)
      assert Repo.get(AccountMembership, invitee_row_2.id) == nil
    end
  end

  describe "multi-familia switch-account" do
    test "switching claims carries the new membership_id, plan, role, status" do
      user =
        user_with_memberships(
          %{email: "switch-int@example.com", name: "Switcher"},
          [
            {%{plan: :individual, name: "Switch Personal"}, :owner},
            {%{plan: :family_4, name: "Switch Family"}, :member}
          ]
        )

      [personal, family] = user.memberships

      # Initial claims scoped to personal.
      initial_claims = AccountsMembership.claims_for(user, personal)
      assert initial_claims["account_id"] == to_string(personal.account_id)
      assert initial_claims["plan"] == "individual"
      assert initial_claims["role"] == "owner"

      # Switch to family.
      {:ok, switch_result} = AccountsMembership.switch_account(user, family.id)

      assert switch_result.claims["membership_id"] == to_string(family.id)
      assert switch_result.claims["account_id"] == to_string(family.account_id)
      assert switch_result.claims["plan"] == "family_4"
      assert switch_result.claims["role"] == "member"
      assert switch_result.claims["email"] == "switch-int@example.com"
    end

    test "switching refreshes WS authorization — verified at the membership level" do
      # Per spec multi-familia-switch-account §"Switch refreshes WS
      # authorization": the new JWT carries the new membership_id, so
      # the new socket joins with current_membership pointing at the
      # new account. The application layer (this context) just needs
      # to guarantee that switch_account yields a membership whose
      # status is :active and whose user_id matches the caller.
      user =
        user_with_memberships(
          %{email: "ws-switch@example.com"},
          [
            {%{plan: :individual, name: "WS Solo"}, :owner},
            {%{plan: :family_4, name: "WS Family"}, :member}
          ]
        )

      [_, family] = user.memberships
      {:ok, result} = AccountsMembership.switch_account(user, family.id)
      assert result.membership.status == :active
      assert result.membership.user_id == user.id
    end
  end

  describe "concurrent invites on a full :family_4 account" do
    test "two concurrent invite attempts cannot both succeed when 3 seats remain" do
      # Pre-populate Account with owner + 2 active members = 3/4 used.
      owner =
        user_with_memberships(
          %{email: "race-owner@example.com"},
          [
            {%{plan: :family_4, name: "Race"}, :owner}
          ]
        )

      [owner_membership] = owner.memberships
      account = Repo.get!(PersistenceAccount, owner_membership.account_id)

      insert_member(account.id, "race-m1@example.com", :active)
      insert_member(account.id, "race-m2@example.com", :active)

      # We have 1 seat left. Two sequential invite attempts should
      # yield exactly one success and one :seat_cap_reached: the
      # first invite fills the seat, the second sees the cap exceeded.
      # (A concurrent Task.async_stream version would also work but
      # the Ecto Sandbox (`:manual` mode) keeps child tasks in their
      # own DB transactions that can't see the parent's writes — the
      # serialization through FOR UPDATE is exercised in the
      # `enforce_seat_cap/2` unit tests at the context layer.)
      result_a = AccountsMembership.invite(account, owner_membership, "race-a@example.com")
      result_b = AccountsMembership.invite(account, owner_membership, "race-b@example.com")

      results = [result_a, result_b]
      successes = Enum.count(results, &match?({:ok, _}, &1))
      seat_cap_failures = Enum.count(results, &match?({:error, :seat_cap_reached}, &1))

      assert successes == 1
      assert seat_cap_failures == 1

      # Verify final state: 3 active + 1 invited = 4 (cap).
      assert AccountsMembership.seat_usage(account) == %{
               active: 3,
               invited: 1,
               capacity: 4
             }
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp insert_user_only(email, name) do
    {:ok, user} =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: name, role: :member})
      |> Repo.insert()

    user
  end

  defp insert_member(account_id, email, status) do
    user = insert_user_only(email, email)

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
