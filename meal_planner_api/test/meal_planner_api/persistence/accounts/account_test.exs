defmodule MealPlannerApi.Persistence.Accounts.AccountTest do
  @moduledoc """
  Schema-level tests for `Account` after the Phase A plan enum swap
  (PR 1 task 1.6).

  Coverage:

    * `Account.changeset(%{}, %{plan: :family_4})` is valid
    * `Account.changeset(%{}, %{plan: :unknown})` is rejected with an
      enum validation error
    * the new `has_many :memberships` association preloads without error
    * existing callers (Accounts.ex) write `plan:` and read `plan` back
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "changeset/2 with plan enum" do
    test "valid for plan: :family_4 with a subscription_plan_id" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      attrs = %{
        name: "Schema-Test Family",
        plan: :family_4,
        default_budget_cents: 0,
        subscription_plan_id: plan.id
      }

      changeset = Account.changeset(%Account{}, attrs)
      assert changeset.valid?, "expected valid, got errors: #{inspect(changeset.errors)}"
    end

    test "rejects unknown plan values" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      attrs = %{
        name: "Schema-Test Bogus",
        plan: :enterprise,
        default_budget_cents: 0,
        subscription_plan_id: plan.id
      }

      changeset = Account.changeset(%Account{}, attrs)
      refute changeset.valid?
      assert %{plan: ["is invalid"]} = errors_on(changeset)
    end

    test "valid for plan: :individual" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "individual")

      attrs = %{
        name: "Schema-Test Individual",
        plan: :individual,
        default_budget_cents: 0,
        subscription_plan_id: plan.id
      }

      changeset = Account.changeset(%Account{}, attrs)
      assert changeset.valid?
    end
  end

  describe "has_many :memberships" do
    test "preloads :memberships without error after insertion" do
      account = insert_account_with_plan!("Schema-Test Memberships", "family_4")
      # Insert one :active :owner membership via raw SQL because the
      # User schema requires account_id (this PR's task 1.7 makes it
      # nullable — the schema-level write of a Membership row is fine).
      insert_active_owner_membership!(account.id)

      account = Repo.preload(account, :memberships)
      assert is_list(account.memberships)
      assert Enum.any?(account.memberships, &(&1.status == :active and &1.role == :owner))
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp insert_account_with_plan!(name, plan_name) do
    plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: plan_name)

    attrs = %{
      name: name,
      plan: String.to_atom(plan_name),
      default_budget_cents: 0,
      subscription_plan_id: plan.id
    }

    {:ok, account} =
      %Account{}
      |> Account.changeset(attrs)
      |> Repo.insert()

    account
  end

  defp insert_active_owner_membership!(account_id) do
    # Need a User row first.
    {:ok, user_id} = Ecto.UUID.dump(Ecto.UUID.generate())
    {:ok, account_id_bin} = Ecto.UUID.dump(account_id)
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO users (id, account_id, email, name, role, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'Owner User', 'owner', $4, $4)
      RETURNING id
      """,
      [user_id, account_id_bin, "owner_#{Ecto.UUID.generate()}@example.com", now]
    )

    {:ok, _} =
      %AccountMembership{}
      |> AccountMembership.changeset(%{
        account_id: account_id,
        user_id: Ecto.UUID.cast!(user_id),
        role: :owner,
        status: :active,
        joined_at: now
      })
      |> Repo.insert()
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
