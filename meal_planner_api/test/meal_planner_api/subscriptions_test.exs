defmodule MealPlannerApi.SubscriptionsTest do
  @moduledoc """
  Tests for `MealPlannerApi.Subscriptions` — Phase A — Tenancy Refactor,
  PR 2a task 2.11.

  Per design §5.2 (PR 2 scope) and `specs/account-membership.md`
  §"Account.plan enum and subscription_plans seed":

    * `policy_for_account/1` resolves through `Account.plan` →
      `subscription_plans` by name (replacing the legacy
      `account_type` lookup that PR 1 removed from the schema).
    * The `:family_6` and `:trial` plans resolve to `max_users: 6`.
    * Unknown plans return an error tuple.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions
  alias MealPlannerApi.Subscriptions.Plan

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  test "get_plan_by_name fetches seeded plan from database" do
    assert {:ok, plan} = Subscriptions.get_plan_by_name("family_4")
    assert plan.name == "family_4"
    assert plan.max_users == 4
    assert plan.max_planning_days == 7
  end

  test "max_planning_days resolves from account plan" do
    {:ok, account} =
      MealPlannerApi.Persistence.Accounts.create_account(%{
        name: "Subscription test account",
        plan: :family_4,
        default_budget_cents: 50_000
      })

    assert {:ok, 7} = Subscriptions.max_planning_days(account.id)
  end

  describe "policy_for_account/1 — Account.plan resolution (PR 2a task 2.11)" do
    test ":family_6 plan resolves to max_users: 6" do
      account = insert_account!(:family_6, "policy-f6")
      assert {:ok, plan_row} = Subscriptions.get_plan_by_name("family_6")

      policy = Subscriptions.policy_for_account(account.id)

      assert policy.max_users == 6
      assert policy.name == "family_6"
      assert policy.max_planning_days == plan_row.max_planning_days
    end

    test ":trial plan resolves to max_users: 6 (reuses :family_6 cap per design Q10)" do
      account = insert_account!(:trial, "policy-trial")
      policy = Subscriptions.policy_for_account(account.id)

      assert policy.max_users == 6
      assert policy.name == "trial"
    end

    test ":family_4 plan resolves to max_users: 4" do
      account = insert_account!(:family_4, "policy-f4")
      policy = Subscriptions.policy_for_account(account.id)

      assert policy.max_users == 4
      assert policy.name == "family_4"
    end

    test ":individual plan resolves to max_users: 1" do
      account = insert_account!(:individual, "policy-ind")
      policy = Subscriptions.policy_for_account(account.id)

      assert policy.max_users == 1
      assert policy.name == "individual"
    end

    test "missing subscription_plans row for the plan returns %{error: reason}" do
      # Create an Account whose subscription_plan_id is nil and whose
      # Account.plan matches a row we then delete. The fallback path
      # in `get_plan_for_account/1` looks up the plan by name and
      # returns :plan_not_found when the row is gone.
      account =
        %PersistenceAccount{}
        |> PersistenceAccount.changeset(%{
          name: "No Plan Row",
          plan: :family_4,
          default_budget_cents: 0
        })
        |> Repo.insert!()

      # Delete the matching subscription_plans row to provoke the
      # :plan_not_found branch.
      case Subscriptions.get_plan_by_name("family_4") do
        {:ok, plan_row} -> Repo.delete!(plan_row)
        _ -> :ok
      end

      policy = Subscriptions.policy_for_account(account.id)
      assert policy.error == "plan_not_found"
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp insert_account!(plan, name) do
    {:ok, plan_row} = Subscriptions.get_plan_by_name(Atom.to_string(plan))

    {:ok, account} =
      MealPlannerApi.Persistence.Accounts.create_account(%{
        name: name,
        plan: plan,
        default_budget_cents: 0,
        subscription_plan_id: plan_row.id
      })

    account
  end
end
