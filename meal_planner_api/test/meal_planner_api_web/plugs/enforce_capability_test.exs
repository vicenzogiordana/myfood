defmodule MealPlannerApiWeb.Plugs.EnforceCapabilityTest do
  @moduledoc """
  Direct plug-level coverage for `EnforceCapability`
  (`revenuecat-access-enforcement`, PR 3 — HTTP capability and recovery).

  The plug runs in the authenticated `:api` pipeline AFTER `:auth`. It
  consults `MealPlannerApi.AccountAccess.eligible?/1` (the same predicate
  channel joins use) and either passes through or halts with `403
  subscription_required`.

  When `revenuecat_access_enforcement` is disabled (the rollout default
  until the signed pipeline is verified in production — see
  `design.md` §"Migration / Rollout"), the plug is a no-op.

  The plug must NOT delete Account data on denial.
  """

  # `async: false` because the setup below mutates the global
  # `:revenuecat_access_enforcement` Application env. An async-enabled
  # run would let a sibling test (e.g. an async routed HTTP test that
  # expects the flag to remain false) read the `true` we set here and
  # fail with a spurious 403. The verify pass observed exactly that
  # race with `CalendarControllerTest`.
  use ExUnit.Case, async: false

  import Plug.Test

  alias MealPlannerApi.Persistence.Accounts, as: AccountsPersistence
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo
  alias MealPlannerApiWeb.Plugs.EnforceCapability

  setup do
    # Explicit checkout — `test_helper.exs` starts the sandbox in `:auto`
    # mode, but other test files in the suite (notably
    # `ChannelCase`/`Generation.ServerTest`) flip it to `:shared` and
    # never restore. Without an explicit checkout, the first
    # `Repo.insert!` in this file raises `DBConnection.OwnershipError`
    # once the suite reaches this point in execution order.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    previous = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)

    # Always restore to the test-config default (`false` in
    # `config/test.exs`). Restoring to `previous` would leak the `true`
    # any earlier test that touched the flag may have left behind — the
    # verify pass observed exactly that race against
    # `CalendarControllerTest`.
    on_exit(fn ->
      Application.put_env(
        :meal_planner_api,
        :revenuecat_access_enforcement,
        Application.get_env(:meal_planner_api, :revenuecat_access_enforcement_default, false)
      )

      # Silence "previous unused" without changing the test's runtime
      # behaviour: the captured value documents what was leaked in.
      _ = previous
    end)

    Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)

    account = insert_account!()

    {:ok, user} =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{
        email: "rc_plug_#{Ecto.UUID.generate()}@myfood.local",
        name: "RC Plug User #{Ecto.UUID.generate()}",
        role: :member
      })
      |> Repo.insert()

    {:ok, _} =
      AccountsPersistence.upsert_revenuecat_customer(%{
        account_id: account.id,
        user_id: user.id,
        rc_app_user_id: "rc_app_user_plug_#{account.id}"
      })

    %{account: account, user_id: user.id}
  end

  describe "when enforcement is enabled" do
    test "eligible account passes through with 403 unblocked and Account intact",
         %{account: account} do
      conn = build_conn_for(account, :trial)

      assert %Plug.Conn{halted: false, status: status} = EnforceCapability.call(conn, [])
      assert status != 403

      # The Account and its customer mapping must still exist.
      assert Repo.get!(PersistenceAccount, account.id)
      assert AccountsPersistence.get_revenuecat_customer_by_app_user_id(customer_id(account))
    end

    test "expired account halts with 403 subscription_required without deleting data",
         %{account: account} do
      conn = build_conn_for(account, :expired)

      assert %Plug.Conn{halted: true, status: 403, resp_body: body} =
               EnforceCapability.call(conn, [])

      assert body =~ ~s("error":"subscription_required")

      # The Account and its data must remain after the denial.
      assert Repo.get!(PersistenceAccount, account.id)
      assert AccountsPersistence.get_revenuecat_customer_by_app_user_id(customer_id(account))
    end

    test "missing current_membership halts with 403 (defense in depth)", %{account: _account} do
      conn =
        :get
        |> conn("/api/cooking/start")
        |> Map.put(:assigns, %{})

      assert %Plug.Conn{halted: true, status: 403, resp_body: body} =
               EnforceCapability.call(conn, [])

      assert body =~ ~s("error":"subscription_required")
    end
  end

  describe "when enforcement is disabled" do
    test "the plug is a no-op even for an expired Account", %{account: account} do
      Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, false)

      conn = build_conn_for(account, :expired)

      assert %Plug.Conn{halted: false} = EnforceCapability.call(conn, [])
    end
  end

  # ─── helpers ────────────────────────────────────────────────────────────

  defp build_conn_for(%PersistenceAccount{} = account, eligibility) do
    persisted = persist_eligibility(account, eligibility)

    membership = %{account_id: persisted.id, account: persisted}

    :get
    |> conn("/api/cooking/start")
    |> Plug.Conn.assign(:current_membership, membership)
  end

  # The plug consults `AccountAccess.eligible?/1`, which loads the Account
  # from the DB. Persist the trial dates here so the plug sees them.
  defp persist_eligibility(%PersistenceAccount{} = account, :trial) do
    started = DateTime.utc_now()
    ends = DateTime.add(started, 7 * 86_400, :second)

    {:ok, updated} =
      account
      |> PersistenceAccount.changeset(%{trial_started_at: started, trial_ends_at: ends})
      |> Repo.update()

    updated
  end

  defp persist_eligibility(%PersistenceAccount{} = account, :expired) do
    past = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    {:ok, updated} =
      account
      |> PersistenceAccount.changeset(%{trial_started_at: past, trial_ends_at: past})
      |> Repo.update()

    updated
  end

  defp persist_eligibility(%PersistenceAccount{} = account, _), do: account

  defp insert_account! do
    {:ok, account} =
      %PersistenceAccount{}
      |> PersistenceAccount.changeset(%{
        name: "Capability Plug #{Ecto.UUID.generate()}",
        plan: :individual,
        default_budget_cents: 0
      })
      |> Repo.insert()

    account
  end

  defp customer_id(account), do: "rc_app_user_plug_#{account.id}"
end
