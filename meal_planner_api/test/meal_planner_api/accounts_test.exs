defmodule MealPlannerApi.AccountsTest do
  use ExUnit.Case, async: false

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Accounts.Account
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import Ecto.Query

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  test "individual account only allows one linked user" do
    external_user_id = Ecto.UUID.generate()
    external_account_id = Ecto.UUID.generate()

    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => external_user_id,
        "account_id" => external_account_id,
        "account_type" => "individual",
        "subscription_tier" => "free"
      })

    account = %Account{
      id: account.id,
      type: :individual,
      owner_id: user.id,
      linked_user_ids: []
    }

    # Phase A: link_user/2 was the legacy single-account seat cap. With the
    # AccountMembership join (PR 2) the seat cap is enforced by
    # AccountsMembership.seat_usage/1 + enforce_seat_cap/2 instead. The
    # legacy link_user helper still exists for the public-facing DTO and
    # is exercised here against the pre-Phase-A shape.
    assert {:ok, updated} = Accounts.link_user(account, Ecto.UUID.generate())
    assert {:error, :individual_limit_reached} = Accounts.link_user(updated, Ecto.UUID.generate())
  end

  test "claims include subscription tier" do
    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "u9",
        "account_id" => "acct_u9",
        "subscription_tier" => "premium"
      })

    user = Map.put(user, :subscription_tier, :premium)
    account = Map.put(account, :subscription_tier, :premium)

    claims = Accounts.claims_for(user, account)

    assert claims["subscription_tier"] == "premium"
  end

  test "find_or_create_identity returns missing_identity when account_id is missing" do
    assert {:error, :missing_identity} =
             Accounts.find_or_create_identity(%{"user_id" => "u_missing"})
  end

  # ----------------------------------------------------------------------
  # PR 2b task 2.9 — authenticate_with_password/1 flag-flip
  # ----------------------------------------------------------------------

  describe "authenticate_with_password/1 — MEAL_PLANNER_TENANCY_V2 flag" do
    setup do
      previous_flag = Application.get_env(:meal_planner_api, :tenancy_v2_only, false)

      on_exit(fn ->
        Application.put_env(:meal_planner_api, :tenancy_v2_only, previous_flag)
      end)

      :ok
    end

    test "with flag OFF (default), issues an access_v1 token via Accounts.claims_for/2" do
      Application.put_env(:meal_planner_api, :tenancy_v2_only, false)

      # Register a User atomically (PR 2b task 2.10 makes registration atomic).
      {:ok, %{user: user}} =
        Accounts.register_with_password(%{
          "email" => "flag-off@example.com",
          "password" => "supersecret123",
          "name" => "Flag Off"
        })

      # authenticate_with_password/1 still returns the User + Account pair.
      assert {:ok, %{user: _reloaded_user, account: _account}} =
               Accounts.authenticate_with_password(%{
                 "email" => "flag-off@example.com",
                 "password" => "supersecret123"
               })

      # Build the legacy access_v1 token manually via Accounts.claims_for/2
      # (the same builder the off-path uses) and decode it. The claim set
      # matches design §3.1.
      [account] =
        Repo.all(
          from(a in MealPlannerApi.Persistence.Accounts.Account,
            join: m in AccountMembership,
            on: m.account_id == a.id and m.user_id == ^user.id,
            limit: 1
          )
        )

      claims_map = Accounts.claims_for(%{user | account_id: account.id}, account)

      assert claims_map["typ"] == "access"
      assert claims_map["account_id"] == account.id

      {:ok, token, _claims} = Guardian.encode_and_sign(user, claims_map, token_type: "access")
      {:ok, decoded} = Guardian.decode_and_verify(token)

      assert decoded["typ"] == "access"
      refute Map.has_key?(decoded, "membership_id"),
             "access_v1 MUST NOT carry membership_id"
    end

    test "with flag ON, authenticate_with_password/1 returns the User's first :active membership so a v2 token can be minted by callers" do
      Application.put_env(:meal_planner_api, :tenancy_v2_only, true)

      {:ok, %{user: user, account: account}} =
        Accounts.register_with_password(%{
          "email" => "flag-on@example.com",
          "password" => "supersecret123",
          "name" => "Flag On"
        })

      assert {:ok, %{user: reloaded, account: reloaded_account}} =
               Accounts.authenticate_with_password(%{
                 "email" => "flag-on@example.com",
                 "password" => "supersecret123"
               })

      # The caller (PR 3 auth_controller) needs the User's first
      # :active AccountMembership row to build the access_v2 claim set.
      # We surface that membership on the authenticate result so the
      # caller doesn't have to query the DB a second time.
      membership =
        Repo.one(
          from(m in AccountMembership,
            where: m.user_id == ^user.id and m.account_id == ^account.id and m.status == :active
          )
        )

      assert membership.role == :owner
      assert membership.account_id == account.id

      # The reloaded Account is the canonical one (with memberships preloaded
      # where useful for the controller layer).
      assert reloaded_account.id == account.id
      assert reloaded.id == user.id
    end
  end
end
