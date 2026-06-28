defmodule MealPlannerApi.AccountsMembershipClaimsTest do
  @moduledoc """
  Tests for `MealPlannerApi.AccountsMembership.claims_for/2` — the
  builder for the `access_v2` JWT claim map (Phase A — Tenancy Refactor,
  PR 2a, task 2.1).

  Per `design.md` §3.2 the claim shape is:

      %{
        "sub"            => <user_id string>,
        "typ"            => "access_v2",
        "membership_id"  => <membership_uuid string>,
        "account_id"     => <account_uuid string>,
        "role"           => "owner" | "member",
        "plan"           => "individual" | "family_4" | "family_6" | "trial",
        "status"         => "active" | "invited" | "suspended",
        "email"          => <email>,
        "name"           => <name>
      }

  `iat` and `exp` are Guardian-managed (added at sign time) and are not
  the responsibility of this builder.
  """
  use ExUnit.Case, async: false

  import MealPlannerApi.FactoryHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Persistence.Accounts.AccountMembership, as: PersistenceAccountMembership
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "claims_for/2 — access_v2 claim shape" do
    test "returns the full access_v2 claim map (design §3.2)" do
      user =
        user_with_memberships(
          %{email: "claims@example.com", name: "Claims User"},
          [
            {%{plan: :family_4, name: "Claims Family"}, :owner}
          ]
        )

      [membership] = user.memberships
      claims = AccountsMembership.claims_for(user, membership)

      assert claims["typ"] == "access_v2"
      assert claims["membership_id"] == Ecto.UUID.cast!(membership.id)
      assert claims["account_id"] == Ecto.UUID.cast!(membership.account_id)
      assert claims["role"] == "owner"
      assert claims["plan"] == "family_4"
      assert claims["status"] == "active"
      assert claims["email"] == "claims@example.com"
      assert claims["name"] == "Claims User"
    end

    test "does NOT include iat or exp (Guardian-managed, not application claims)" do
      user =
        user_with_memberships(
          %{email: "no-iat@example.com"},
          [
            {%{plan: :individual, name: "Solo"}, :owner}
          ]
        )

      [membership] = user.memberships
      claims = AccountsMembership.claims_for(user, membership)

      refute Map.has_key?(claims, "iat")
      refute Map.has_key?(claims, "exp")
    end

    test "preloads the account plan when the membership hasn't preloaded :account" do
      user =
        user_with_memberships(
          %{email: "no-preload@example.com"},
          [
            {%{plan: :family_6, name: "Big"}, :member}
          ]
        )

      [membership] = user.memberships

      # Re-load without preload to prove the builder does its own lookup.
      bare_membership = Repo.get!(PersistenceAccountMembership, membership.id)
      refute Ecto.assoc_loaded?(bare_membership.account)

      claims = AccountsMembership.claims_for(user, bare_membership)

      assert claims["plan"] == "family_6"
      assert claims["role"] == "member"
    end

    test "serializes role and plan as strings (not atoms)" do
      user =
        user_with_memberships(
          %{email: "string-claims@example.com"},
          [
            {%{plan: :trial, name: "Trial Family"}, :member}
          ]
        )

      [membership] = user.memberships
      claims = AccountsMembership.claims_for(user, membership)

      assert is_binary(claims["role"])
      assert is_binary(claims["plan"])
      assert claims["role"] == "member"
      assert claims["plan"] == "trial"
    end
  end
end
