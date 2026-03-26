defmodule MealPlannerApi.AccountsTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Accounts.Account
  alias MealPlannerApi.Repo
  alias Ecto.Adapters.SQL.Sandbox

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
end
