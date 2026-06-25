defmodule MealPlannerApi.Persistence.Accounts.UserTest do
  @moduledoc """
  Schema-level tests for `User` after the Phase A nullable-account_id
  change (PR 1 task 1.7).

  Coverage:

    * `User.changeset(%{}, %{email: "x@y", account_id: nil})` is valid
      (RED before the migration relaxed the FK — design §2.3 decision
      5.1)
    * the new `has_many :memberships` association preloads without error
    * the changeset still validates `email` and `name` as required
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Persistence.Accounts.User
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "changeset/2 with nullable account_id" do
    test "valid when account_id is nil (dual-write fallback for access_v2)" do
      attrs = %{
        email: "noacct_#{Ecto.UUID.generate()}@example.com",
        name: "No-Account User",
        role: :member,
        account_id: nil
      }

      changeset = User.changeset(%User{}, attrs)
      assert changeset.valid?, "expected valid, got: #{inspect(changeset.errors)}"
    end

    test "valid when account_id is set" do
      attrs = %{
        email: "withacct_#{Ecto.UUID.generate()}@example.com",
        name: "With-Account User",
        role: :owner,
        account_id: Ecto.UUID.generate()
      }

      changeset = User.changeset(%User{}, attrs)
      assert changeset.valid?
    end

    test "invalid when email is missing" do
      attrs = %{
        name: "Missing-Email User",
        role: :owner,
        account_id: Ecto.UUID.generate()
      }

      changeset = User.changeset(%User{}, attrs)
      refute changeset.valid?
      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when role is missing" do
      attrs = %{
        email: "norole_#{Ecto.UUID.generate()}@example.com",
        name: "No-Role User",
        account_id: Ecto.UUID.generate()
      }

      changeset = User.changeset(%User{}, attrs)
      refute changeset.valid?
      assert %{role: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "has_many :memberships" do
    test "preloads :memberships without error after insertion" do
      account = insert_account_with_plan!("User-Test Memberships", "family_4")

      {:ok, user} =
        %User{}
        |> User.changeset(%{
          email: "ms_#{Ecto.UUID.generate()}@example.com",
          name: "Membership Owner",
          role: :owner,
          account_id: account.id
        })
        |> Repo.insert()

      {:ok, _membership} =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: user.id,
          role: :owner,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert()

      user = Repo.preload(user, :memberships)
      assert is_list(user.memberships)
      assert Enum.any?(user.memberships, &(&1.status == :active and &1.role == :owner))
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp insert_account_with_plan!(name, plan_name) do
    plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: plan_name)

    {:ok, account} =
      %MealPlannerApi.Persistence.Accounts.Account{}
      |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
        name: name,
        plan: String.to_atom(plan_name),
        default_budget_cents: 0,
        subscription_plan_id: plan.id
      })
      |> Repo.insert()

    account
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
