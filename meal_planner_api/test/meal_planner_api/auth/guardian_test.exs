defmodule MealPlannerApi.Auth.GuardianTest do
  @moduledoc """
  Dual-write JWT shape test (Phase A — Tenancy Refactor, PR 1 task 1.14).

  Per `design.md` §8.4 + spec `guardian-jwt-claims.md`:

    * `access_v1` claim set per design §3.1: `sub`, `typ`, `account_id`,
      `account_type`, `subscription_tier`, `email`, `name`, `iat`, `exp`
    * `access_v2` claim set per design §3.2: every key from §3.1 PLUS
      `membership_id`, `plan`, `role`, `status`
    * An unknown `typ` is rejected by `AuthPipeline.VerifyTokenType` (the
      underlying Guardian decode succeeds; rejection is the plug's job —
      delegated to `MealPlannerApiWeb.AuthPipelineTest`).

  This test is the bridge between spec §3 (claim shape) and the
  pipeline in task 1.11 (auth verification). It proves the JWT shape
  independent of any controller.
  """
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Repo

  describe "access_v1 claim shape (design §3.1)" do
    test "mints a token with the full §3.1 claim set" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "V1 Claim Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "v1-claim@example.com",
          name: "V1 Claim",
          role: :owner
        })
        |> Repo.insert()

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

      # §3.1 keys — every one present
      for key <- [
            "sub",
            "typ",
            "account_id",
            "account_type",
            "subscription_tier",
            "email",
            "name",
            "iat",
            "exp"
          ] do
        assert Map.has_key?(decoded, key), "expected #{key} in access_v1 claim set"
      end

      assert decoded["typ"] == "access"
      assert decoded["account_id"] == Ecto.UUID.cast!(account.id)
      assert decoded["account_type"] == "group"
      assert decoded["subscription_tier"] == "premium"
      assert decoded["email"] == user.email
      assert decoded["name"] == user.name
      assert decoded["sub"] == Ecto.UUID.cast!(user.id)
      assert is_integer(decoded["iat"])
      assert is_integer(decoded["exp"])
      assert decoded["exp"] > decoded["iat"]
    end
  end

  describe "access_v2 claim shape (design §3.2)" do
    test "mints a token with every §3.2 claim populated from the membership" do
      user =
        user_with_memberships(
          %{email: "v2-claim@example.com"},
          [
            {%{plan: :family_4, name: "V2 Claim Family"}, :owner}
          ]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)
      {:ok, decoded} = Guardian.decode_and_verify(token)

      # §3.2 keys — every one present
      for key <- [
            "sub",
            "typ",
            "membership_id",
            "account_id",
            "role",
            "plan",
            "status",
            "email",
            "name",
            "iat",
            "exp"
          ] do
        assert Map.has_key?(decoded, key), "expected #{key} in access_v2 claim set"
      end

      assert decoded["typ"] == "access_v2"
      assert decoded["membership_id"] == Ecto.UUID.cast!(membership.id)
      assert decoded["account_id"] == Ecto.UUID.cast!(membership.account_id)
      assert decoded["role"] == "owner"
      assert decoded["plan"] == "family_4"
      assert decoded["status"] == "active"
      assert decoded["email"] == user.email
      assert decoded["name"] == user.name
      assert decoded["sub"] == Ecto.UUID.cast!(user.id)
    end

    test "decoded values match the underlying membership row, not stale claims" do
      user =
        user_with_memberships(
          %{email: "v2-fresh@example.com"},
          [
            {%{plan: :trial, name: "Trial Family"}, :member}
          ]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)
      {:ok, decoded} = Guardian.decode_and_verify(token)

      assert decoded["plan"] == "trial"
      assert decoded["role"] == "member"
      assert decoded["status"] == "active"
    end
  end

  describe "factory_helpers issue_access_v2_token/2 is the canonical entry point" do
    test "produces a token that verifies under both Guardian and the pipeline" do
      user =
        user_with_memberships(
          %{email: "factory-token@example.com"},
          [
            {%{plan: :family_6, name: "Family 6 Factory"}, :owner}
          ]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      {:ok, claims} = Guardian.decode_and_verify(token)
      assert claims["typ"] == "access_v2"

      # The factory token MUST carry the same membership_id we passed
      # in (otherwise the pipeline can't load the membership).
      assert claims["membership_id"] == Ecto.UUID.cast!(membership.id)
    end
  end
end
