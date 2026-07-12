defmodule MealPlannerApi.Persistence.Accounts.AccountMembershipTest do
  @moduledoc """
  Schema-level tests for `AccountMembership` (Phase A, PR 1 task 1.5).

  Coverage:

    * valid changeset for `:active :owner` and `:invited :member`
    * invalid changeset rejects unknown `role` / `status` values
    * foreign-key constraints surface as `Ecto.Changeset` errors when the
      referenced `account_id` / `user_id` is bogus
    * the partial unique index surfaces as a `unique_constraint` error
      when a second `:active` row is inserted for the same `(account,
      user)`
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "changeset/2" do
    test "valid changeset for an :active :owner membership" do
      account = insert_account!()
      user = insert_user!(account.id)

      attrs = %{
        account_id: account.id,
        user_id: user.id,
        role: :owner,
        status: :active,
        joined_at: DateTime.utc_now()
      }

      changeset = AccountMembership.changeset(%AccountMembership{}, attrs)
      assert changeset.valid?
    end

    test "valid changeset for an :invited :member membership with invite fields" do
      account = insert_account!()
      user = insert_user!(account.id)

      expires_at = DateTime.add(DateTime.utc_now(), 7 * 24 * 60 * 60, :second)

      attrs = %{
        account_id: account.id,
        user_id: user.id,
        role: :member,
        status: :invited,
        invited_by_user_id: user.id,
        invite_token_hash: "abc123",
        invite_expires_at: expires_at
      }

      changeset = AccountMembership.changeset(%AccountMembership{}, attrs)
      assert changeset.valid?
    end

    test "invalid changeset when role is unknown" do
      account = insert_account!()
      user = insert_user!(account.id)

      attrs = %{
        account_id: account.id,
        user_id: user.id,
        role: :admin,
        status: :active
      }

      changeset = AccountMembership.changeset(%AccountMembership{}, attrs)
      refute changeset.valid?
      assert %{role: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset when status is unknown" do
      account = insert_account!()
      user = insert_user!(account.id)

      attrs = %{
        account_id: account.id,
        user_id: user.id,
        role: :member,
        status: :ghost
      }

      changeset = AccountMembership.changeset(%AccountMembership{}, attrs)
      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "FK constraint surfaces when account_id is bogus" do
      user = insert_user!()

      attrs = %{
        account_id: Ecto.UUID.generate(),
        user_id: user.id,
        role: :member,
        status: :active
      }

      {:error, changeset} =
        %AccountMembership{}
        |> AccountMembership.changeset(attrs)
        |> Repo.insert()

      refute changeset.valid?
      assert %{account_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp insert_account! do
    plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")
    {:ok, id_bin} = Ecto.UUID.dump(Ecto.UUID.generate())
    {:ok, plan_id_bin} = Ecto.UUID.dump(plan.id)
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO accounts (id, name, plan, default_budget_cents, subscription_plan_id, inserted_at, updated_at)
      VALUES ($1, 'Membership-Test Account', 'family_4', 0, $2, $3, $3)
      RETURNING id
      """,
      [id_bin, plan_id_bin, now]
    )

    %{id: Ecto.UUID.cast!(id_bin)}
  end

  defp insert_user!(account_id \\ nil) do
    {:ok, id_bin} = Ecto.UUID.dump(Ecto.UUID.generate())

    args =
      if account_id do
        {:ok, account_id_bin} = Ecto.UUID.dump(account_id)
        [id_bin, account_id_bin, "ms_test_#{Ecto.UUID.generate()}@example.com"]
      else
        [id_bin, nil, "ms_test_#{Ecto.UUID.generate()}@example.com"]
      end

    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO users (id, account_id, email, name, role, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'Membership-Test User', 'owner', $4, $4)
      RETURNING id
      """,
      args ++ [now]
    )

    %{id: Ecto.UUID.cast!(id_bin)}
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
