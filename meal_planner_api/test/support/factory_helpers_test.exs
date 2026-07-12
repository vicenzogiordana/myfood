defmodule MealPlannerApi.FactoryHelpersTest do
  @moduledoc """
  Tests for the factory helper macros introduced in PR 1 task 1.8/1.9.

  The macros live in `MealPlannerApi.FactoryHelpers` (a support module
  loaded by `test_helper.exs` ad-hoc; not auto-imported into every test).
  Coverage:

    * `user_with_memberships/2` inserts a User + N Accounts + N
      `:active` memberships and preloads `memberships: :account`
    * `:plan` values round-trip through the AccountMembership join and
      Account schema
    * `issue_access_v2_token/2` mints a JWT with `typ: "access_v2"`
      carrying `membership_id`, `account_id`, `plan`, `role`, `status`
      claims (task 1.9)
  """
  use ExUnit.Case, async: false

  import MealPlannerApi.FactoryHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "user_with_memberships/2" do
    test "creates a User with 2 memberships across 2 Accounts" do
      user =
        user_with_memberships(
          %{email: "multi@example.com"},
          [
            {%{plan: :family_4, name: "Family"}, :owner},
            {%{plan: :individual, name: "Personal"}, :member}
          ]
        )

      assert user.email == "multi@example.com"
      assert length(user.memberships) == 2

      roles = user.memberships |> Enum.map(& &1.role) |> Enum.sort()
      assert roles == [:member, :owner]

      plan_names =
        user.memberships
        |> Enum.map(& &1.account.plan)
        |> Enum.sort_by(&to_string/1)

      assert plan_names == [:family_4, :individual]
    end

    test "the memberships are :active and have joined_at set" do
      user =
        user_with_memberships(
          %{email: "active@example.com"},
          [
            {%{plan: :family_4, name: "F"}, :owner}
          ]
        )

      [membership] = user.memberships
      assert membership.status == :active
      assert membership.role == :owner
      assert %DateTime{} = membership.joined_at
    end

    test "preloads memberships: :account so callers can read plan directly" do
      user =
        user_with_memberships(
          %{email: "preload@example.com"},
          [
            {%{plan: :family_6, name: "Big Family"}, :owner}
          ]
        )

      [membership] = user.memberships
      assert membership.account.plan == :family_6
      assert membership.account.name == "Big Family"
    end
  end

  describe "issue_access_v2_token/2" do
    test "encodes an access_v2 JWT with the access_v2 claim set" do
      user =
        user_with_memberships(
          %{email: "jwt@example.com"},
          [
            {%{plan: :family_4, name: "J Family"}, :owner}
          ]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      assert is_binary(token)
      {:ok, claims} = Guardian.decode_and_verify(token)

      assert claims["typ"] == "access_v2"
      assert claims["membership_id"] == Ecto.UUID.cast!(membership.id)
      assert claims["account_id"] == Ecto.UUID.cast!(membership.account_id)
      assert claims["plan"] == "family_4"
      assert claims["role"] == "owner"
      assert claims["status"] == "active"
      assert claims["email"] == "jwt@example.com"
      assert claims["name"] == user.name
    end

    test "round-trips through Guardian.decode_and_verify with the correct subject" do
      user =
        user_with_memberships(
          %{email: "sub@example.com"},
          [
            {%{plan: :individual, name: "Solo"}, :owner}
          ]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      {:ok, claims} = Guardian.decode_and_verify(token)
      assert claims["sub"] == Ecto.UUID.cast!(user.id)
    end
  end

  # Spot-check that the AccountMembership row written by the factory is
  # observable via the canonical schema.
  test "membership row exists in the DB after user_with_memberships/2" do
    user =
      user_with_memberships(
        %{email: "persist@example.com"},
        [
          {%{plan: :family_4, name: "Persist F"}, :owner}
        ]
      )

    [membership] = user.memberships
    fetched = Repo.get!(AccountMembership, membership.id)
    assert fetched.user_id == user.id
    assert fetched.account_id == membership.account_id
    assert fetched.status == :active
  end
end
