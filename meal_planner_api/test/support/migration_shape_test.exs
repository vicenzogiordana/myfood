defmodule MealPlannerApi.MigrationShapeTest do
  @moduledoc """
  Migration shape tests for Phase A — Tenancy Refactor.

  Each test asserts that the live database carries the schema
  promised by `proposal.md` and `design.md` for PR 1. Tests are
  written FIRST (red), then the corresponding migration is added
  (green), then the migration is reviewed for shape correctness.

  PR 1 covers four migrations:
    * `account_memberships` table (with CHECK + partial unique index)
    * `accounts.account_type → plan` enum swap + `subscription_plans` seed
    * `users.account_id` nullable (dual-write window)
    * Backfill + invariant function

  All assertions hit the live DB via `Repo.query!/1` so they double
  as documentation of the post-Phase-A schema.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "account_memberships table" do
    test "table exists with the expected columns" do
      columns = table_columns("account_memberships")
      assert "id" in columns
      assert "account_id" in columns
      assert "user_id" in columns
      assert "role" in columns
      assert "status" in columns
      assert "invited_by_user_id" in columns
      assert "invite_token_hash" in columns
      assert "invite_expires_at" in columns
      assert "joined_at" in columns
      assert "inserted_at" in columns
      assert "updated_at" in columns
    end

    test "id is a binary (uuid) primary key" do
      data_type = column_data_type("account_memberships", "id")
      assert data_type == "uuid", "expected id to be uuid, got #{data_type}"
    end

    test "role has a CHECK constraint limiting values to owner | member" do
      assert check_constraint_exists?("account_memberships", "account_memberships_role_check"),
             "expected account_memberships_role_check constraint"

      # Use raw SQL with gen_random_uuid() to avoid binary-encoding issues.
      sql = """
      INSERT INTO account_memberships (id, account_id, user_id, role, status, inserted_at, updated_at)
      VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'robot', 'active', now(), now())
      """

      assert_raises_postgres("23514", fn -> Repo.query!(sql, []) end)
    end

    test "status has a CHECK constraint limiting values to active | invited | suspended" do
      assert check_constraint_exists?(
               "account_memberships",
               "account_memberships_status_check"
             ),
             "expected account_memberships_status_check constraint"

      sql = """
      INSERT INTO account_memberships (id, account_id, user_id, role, status, inserted_at, updated_at)
      VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'owner', 'ghost', now(), now())
      """

      assert_raises_postgres("23514", fn -> Repo.query!(sql, []) end)
    end

    test "partial unique index forbids two :active rows for the same (account, user)" do
      # The partial unique index is `account_memberships_active_account_user_unique_index`
      # on (account_id, user_id) WHERE status = 'active'.
      assert partial_index_exists?(
               "account_memberships",
               "account_memberships_active_account_user_unique_index"
             )
    end

    test "inserting two :active rows for the same (account, user) raises unique_violation" do
      account = insert_account!()
      user = insert_user!(account.id)

      attrs = %{
        id: Ecto.UUID.generate(),
        account_id: account.id,
        user_id: user.id,
        role: "member",
        status: "active",
        joined_at: DateTime.utc_now()
      }

      assert {:ok, _} =
               %MealPlannerApi.Persistence.Accounts.AccountMembership{}
               |> MealPlannerApi.Persistence.Accounts.AccountMembership.changeset(attrs)
               |> Repo.insert()

      duplicate = %{
        id: Ecto.UUID.generate(),
        account_id: account.id,
        user_id: user.id,
        role: "member",
        status: "active",
        joined_at: DateTime.utc_now()
      }

      assert {:error, changeset} =
               %MealPlannerApi.Persistence.Accounts.AccountMembership{}
               |> MealPlannerApi.Persistence.Accounts.AccountMembership.changeset(duplicate)
               |> Repo.insert()

      assert %{account_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "accounts.plan enum" do
    test "the legacy account_type column is gone" do
      refute "account_type" in table_columns("accounts"),
             "expected account_type column to be dropped"
    end

    test "the plan column exists with the right type" do
      columns = table_columns("accounts")
      assert "plan" in columns
      assert column_data_type("accounts", "plan") == "text"
    end

    test "plan has a CHECK constraint limiting values" do
      assert check_constraint_exists?("accounts", "accounts_plan_check"),
             "expected accounts_plan_check constraint"
    end

    test "inserting an unknown plan value is rejected by the CHECK constraint" do
      sql = """
      INSERT INTO accounts (id, name, plan, default_budget_cents, subscription_plan_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'X', 'enterprise', 0, $1, now(), now())
      """

      plan_id = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4").id
      assert_raises_postgres("23514", fn -> Repo.query!(sql, [plan_id]) end)
    end
  end

  describe "subscription_plans seed (Q10)" do
    test "all four plan names are seeded" do
      plan_names = Repo.all(from p in MealPlannerApi.Subscriptions.Plan, select: p.name) |> Enum.sort()
      assert plan_names == ["family_4", "family_6", "individual", "trial"]
    end

    test ":family_6 plan has max_users 6" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_6")
      assert plan.max_users == 6
    end

    test ":trial plan has max_users 6" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "trial")
      assert plan.max_users == 6
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp table_columns(table) do
    query = """
    SELECT column_name
    FROM information_schema.columns
    WHERE table_name = $1
    ORDER BY ordinal_position
    """

    rows = Repo.query!(query, [table]).rows
    Enum.map(rows, fn [name] -> name end)
  end

  defp column_data_type(table, column) do
    query = """
    SELECT data_type
    FROM information_schema.columns
    WHERE table_name = $1 AND column_name = $2
    """

    [[data_type]] = Repo.query!(query, [table, column]).rows
    data_type
  end

  defp check_constraint_exists?(table, constraint_name) do
    query = """
    SELECT 1
    FROM information_schema.table_constraints
    WHERE table_name = $1
      AND constraint_name = $2
      AND constraint_type = 'CHECK'
    """

    Repo.query!(query, [table, constraint_name]).rows != []
  end

  defp partial_index_exists?(table, index_name) do
    query = """
    SELECT 1
    FROM pg_indexes
    WHERE tablename = $1 AND indexname = $2
      AND indexdef ILIKE '%WHERE%'
    """

    Repo.query!(query, [table, index_name]).rows != []
  end

  defp assert_raises_postgres(expected_sqlstate, fun) do
    try do
      result = fun.()

      case result do
        {:ok, _} ->
          flunk("expected PostgreSQL exception #{expected_sqlstate}, got :ok")

        other ->
          flunk("expected PostgreSQL exception #{expected_sqlstate}, got #{inspect(other)}")
      end
    rescue
      ex in Postgrex.Error ->
        assert ex.postgres.pg_code == expected_sqlstate,
               "expected sqlstate #{expected_sqlstate}, got pg_code=#{ex.postgres.pg_code} code=#{ex.postgres.code}"
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp insert_account! do
    plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

    %MealPlannerApi.Persistence.Accounts.Account{}
    |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
      name: "Test Account #{Ecto.UUID.generate()}",
      account_type: :group,
      default_budget_cents: 0,
      subscription_plan_id: plan.id
    })
    |> Repo.insert!()
  end

  defp insert_user!(account_id) do
    %MealPlannerApi.Persistence.Accounts.User{}
    |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
      account_id: account_id,
      email: "u_#{Ecto.UUID.generate()}@example.com",
      name: "Test User",
      role: :owner
    })
    |> Repo.insert!()
  end
end
