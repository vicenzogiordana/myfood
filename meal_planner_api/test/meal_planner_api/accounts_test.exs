defmodule MealPlannerApi.AccountsTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Accounts.Account
  alias MealPlannerApi.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  test "individual account only allows one linked user" do
    account = %Account{id: "acct_1", type: :individual, owner_id: "u1", linked_user_ids: []}

    assert {:ok, updated} = Accounts.link_user(account, "u2")
    assert {:error, :individual_limit_reached} = Accounts.link_user(updated, "u3")
  end

  test "claims include subscription tier" do
    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{"user_id" => "u9", "subscription_tier" => "premium"})

    user = Map.put(user, :subscription_tier, :premium)
    account = Map.put(account, :subscription_tier, :premium)

    claims = Accounts.claims_for(user, account)

    assert claims["subscription_tier"] == "premium"
  end
end
