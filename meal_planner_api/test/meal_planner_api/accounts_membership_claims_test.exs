defmodule MealPlannerApi.AccountsMembershipClaimsTest do
  @moduledoc """
  Tests for `MealPlannerApi.AccountsMembership.claims_for/2` — the
  builder for the `access_v2` JWT claim map (Phase A — Tenancy Refactor,
  PR 2a, task 2.1).

  Per `design.md` §3.2 the claim shape is:

      %{
        "sub"            => <user_id string>,
        "typ"            => "access_v2",
        "user_id"        => <user_id string>,     # Phase 3 addition
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

  Phase 3 (issue #31 task 3.1) adds:

    * `claims_for/2` MUST emit an explicit `user_id` claim so the verify
      outcome can mint the JWT without consulting the User struct again.
    * `claims_for/1` MUST exist for the zero-membership outcome — a
      membership-less `access_v2` whose absence of `membership_id`
      causes `LoadCurrentMembership` to halt with `401
      membership_id_required` and route the client to invite acceptance.
  """
  use ExUnit.Case, async: false

  import MealPlannerApi.FactoryHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Persistence.Accounts.AccountMembership, as: PersistenceAccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
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

    # Phase 3 task 3.1 — `claims_for/2` MUST emit an explicit `user_id`
    # claim so the email-code verify outcome can mint the JWT without
    # consulting the User struct again.
    test "explicitly emits the user_id claim (Phase 3 task 3.1)" do
      user =
        user_with_memberships(
          %{email: "uid-claim@example.com", name: "UID"},
          [
            {%{plan: :individual, name: "UID Solo"}, :owner}
          ]
        )

      [membership] = user.memberships
      claims = AccountsMembership.claims_for(user, membership)

      assert claims["user_id"] == Ecto.UUID.cast!(user.id)
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

  # Phase 3 task 3.1 — zero-membership outcome builder. The verify
  # outcome returns this for a User with no `:active` memberships; the
  # caller mints a JWT and `LoadCurrentMembership` halts with `401
  # membership_id_required` because `membership_id` is absent from the
  # claim set. See `specs/email-code-authentication/spec.md` §"Verify
  # Response Outcomes by Active-Membership Count".
  describe "claims_for/1 — no-membership access_v2 (Phase 3 task 3.1)" do
    test "emits access_v2 claims without membership_id, account_id, role, plan, or status" do
      user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "no-membership@example.com",
          name: "No Membership",
          role: :member
        })
        |> Repo.insert!()

      claims = AccountsMembership.claims_for(user)

      assert claims["typ"] == "access_v2"
      assert claims["user_id"] == Ecto.UUID.cast!(user.id)
      assert claims["email"] == "no-membership@example.com"
      assert claims["name"] == "No Membership"

      refute Map.has_key?(claims, "membership_id"),
             "no-membership claims MUST omit membership_id so LoadCurrentMembership returns 401 membership_id_required"

      refute Map.has_key?(claims, "account_id")
      refute Map.has_key?(claims, "role")
      refute Map.has_key?(claims, "plan")
      refute Map.has_key?(claims, "status")
    end

    test "still emits user_id, email, name, typ" do
      user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "no-mem-min@example.com",
          name: "Min",
          role: :member
        })
        |> Repo.insert!()

      claims = AccountsMembership.claims_for(user)

      assert Map.has_key?(claims, "typ")
      assert Map.has_key?(claims, "user_id")
      assert Map.has_key?(claims, "email")
      assert Map.has_key?(claims, "name")
    end
  end
end
