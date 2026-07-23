defmodule MealPlannerApi.Auth.GuardianResourceFromClaimsTest do
  @moduledoc """
  Tests for `MealPlannerApi.Auth.Guardian.resource_from_claims/1` after
  the dual-write auth fix (Phase A — Tenancy Refactor, PR 2b task 2.9).

  Pre-PR-2b, Guardian's `resource_from_claims/1` re-attached `:account_type`,
  `:subscription_tier`, and `:account_id` from claims onto the freshly-
  loaded User struct. That reattachment is now reduced:

    * `:account_type` is **NOT** re-attached. The legacy `:group |
      :individual` taxonomy was dropped from the schema in PR 1
      (replaced by `Account.plan`). The User struct no longer carries
      that field, so re-attaching it gave a stale value that no caller
      should read post-Phase A.
    * `:subscription_tier` IS still re-attached. The PR 3 controller
      sweep (which is **out of PR 2b scope**) still reads
      `user.subscription_tier`; removing the reattachment now would
      break those controllers before they can be migrated.
    * `:account_id` IS still re-attached. The PR 1
      `LoadCurrentMembership.synthesize_legacy_membership/2` reads
      `user.account_id` to seed the synthesized membership struct for
      legacy `access_v1` tokens. Removing the reattachment now would
      break the dual-write fallback before the controller sweep.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "resource_from_claims/1 — reattachment policy" do
    test "does NOT attach :account_type to the loaded User struct" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Dual-Write Auth Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          account_id: account.id,
          email: "no-account-type@example.com",
          name: "No Account Type User",
          role: :owner
        })
        |> Repo.insert()

      # Issue an `access` (legacy) token with an `account_type` claim.
      # Per spec `guardian-jwt-claims.md` §"access_v2 claim shape" the
      # legacy token carries `account_type` for backwards compat — but
      # the User struct MUST NOT inherit it. The plan is the source of
      # truth (read from `current_membership.plan` downstream).
      claims_map = %{
        "typ" => "access",
        "account_id" => Ecto.UUID.cast!(account.id),
        "account_type" => "group",
        "subscription_tier" => "premium",
        "email" => user.email,
        "name" => user.name
      }

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, claims_map, token_type: "access")

      {:ok, decoded} = Guardian.decode_and_verify(token)

      assert {:ok, loaded} = Guardian.resource_from_claims(decoded)

      # The fix: :account_type is NOT on the loaded User struct.
      refute Map.has_key?(loaded, :account_type),
             "Guardian.resource_from_claims/1 must not reattach :account_type (it is a legacy field; Account.plan is the source of truth)"
    end

    test "still attaches :subscription_tier (PR 3 controllers read it)" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Tier Family",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          account_id: account.id,
          email: "tier-still@example.com",
          name: "Tier User",
          role: :owner
        })
        |> Repo.insert()

      claims_map = %{
        "typ" => "access",
        "account_id" => Ecto.UUID.cast!(account.id),
        "subscription_tier" => "premium",
        "email" => user.email,
        "name" => user.name
      }

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, claims_map, token_type: "access")

      {:ok, decoded} = Guardian.decode_and_verify(token)
      assert {:ok, loaded} = Guardian.resource_from_claims(decoded)
      assert loaded.subscription_tier == :premium
    end

    test "still attaches :account_id (LoadCurrentMembership synthesizes from it)" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Account-Id Family",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          account_id: account.id,
          email: "acct-id-still@example.com",
          name: "Account Id User",
          role: :owner
        })
        |> Repo.insert()

      claims_map = %{
        "typ" => "access",
        "account_id" => Ecto.UUID.cast!(account.id),
        "email" => user.email,
        "name" => user.name
      }

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, claims_map, token_type: "access")

      {:ok, decoded} = Guardian.decode_and_verify(token)
      assert {:ok, loaded} = Guardian.resource_from_claims(decoded)
      assert loaded.account_id == account.id
    end

    test "access_v2 token without membership_id is loaded by Guardian but rejected by the pipeline" do
      # This proves that Guardian's resource lookup is decoupled from
      # the membership_id check (which is the LoadCurrentMembership
      # plug's job, not Guardian's).
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Partial V2 Family",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          account_id: account.id,
          email: "partial-v2@example.com",
          name: "Partial V2",
          role: :owner
        })
        |> Repo.insert()

      claims_map = %{
        "typ" => "access_v2",
        "account_id" => Ecto.UUID.cast!(account.id),
        "role" => "owner",
        "plan" => "individual",
        "status" => "active",
        "email" => user.email,
        "name" => user.name
      }

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, claims_map, token_type: "access")

      {:ok, decoded} = Guardian.decode_and_verify(token)
      # Guardian succeeds (User is loadable).
      assert {:ok, _loaded} = Guardian.resource_from_claims(decoded)
      # The membership_id rejection is the pipeline's job — see
      # MealPlannerApiWeb.Plugs.LoadCurrentMembershipTest
      # "access_v2 token without membership_id halts with 401".
      refute Map.has_key?(decoded, "membership_id")
    end

    test "unknown sub (deleted User) returns :resource_not_found" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      {:ok, account} =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "Ghost Family",
          plan: :individual,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      claims_map = %{
        "typ" => "access",
        "sub" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.cast!(account.id),
        "email" => "ghost@example.com",
        "name" => "Ghost"
      }

      {:ok, token, _claims} =
        Guardian.encode_and_sign(%{id: claims_map["sub"]}, claims_map, token_type: "access")

      {:ok, decoded} = Guardian.decode_and_verify(token)
      assert {:error, :resource_not_found} = Guardian.resource_from_claims(decoded)
    end
  end
end
