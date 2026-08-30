defmodule MealPlannerApi.AccountAccessTest do
  @moduledoc """
  Tests for `MealPlannerApi.AccountAccess` — the single Account-wide
  eligibility/status predicate introduced by
  `revenuecat-access-enforcement` (PR 1 — Access State Foundation).

  PR 1 deliberately does NOT exercise the webhook ingestion paths (those
  land in Phase 2 / PR 2). Eligibility is set up directly on the Account
  and RevenuecatEntitlement rows so the predicate itself can be approved
  in isolation.

  Half-open boundary semantics covered:
    * trial_started_at inclusive, trial_ends_at exclusive
    * entitlement expiration_date / grace_period_expires_date strict `>`
    * lifetime grant (both dates nil, is_active=true)
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.RevenuecatEntitlement
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    %{account: account, user: user} = insert_account_and_owner!()
    %{now: DateTime.utc_now(), account: account, user: user}
  end

  describe "eligible?/2 — trial lifecycle" do
    test "Account without trial or entitlement is not eligible", %{account: account, now: now} do
      refute AccountAccess.eligible?(account, now)
    end

    test "Account whose trial covers `now` is eligible", %{account: account} do
      started = DateTime.utc_now() |> DateTime.add(-3600, :second)
      ended = DateTime.utc_now() |> DateTime.add(3600, :second)

      account = put_trial(account, started, ended)
      now = DateTime.utc_now()

      assert AccountAccess.eligible?(account, now)
    end

    test "Account whose trial ended before `now` is NOT eligible", %{account: account} do
      started = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second)
      ended = DateTime.utc_now() |> DateTime.add(-3600, :second)

      account = put_trial(account, started, ended)
      now = DateTime.utc_now()

      refute AccountAccess.eligible?(account, now)
    end

    test "Account whose trial has not started yet is NOT eligible", %{account: account} do
      started = DateTime.utc_now() |> DateTime.add(3600, :second)
      ended = DateTime.utc_now() |> DateTime.add(86_400, :second)

      account = put_trial(account, started, ended)
      now = DateTime.utc_now()

      refute AccountAccess.eligible?(account, now)
    end

    test "Account whose trial ends EXACTLY at `now` is NOT eligible (boundary, half-open)",
         %{account: account} do
      started = DateTime.utc_now() |> DateTime.add(-3600, :second)
      ended = DateTime.utc_now()

      account = put_trial(account, started, ended)

      refute AccountAccess.eligible?(account, ended),
             "now == trial_ends_at must NOT be eligible (half-open: ends_at exclusive)"
    end

    test "Account whose trial starts EXACTLY at `now` IS eligible (boundary, inclusive start)",
         %{account: account} do
      started = DateTime.utc_now()
      ended = DateTime.utc_now() |> DateTime.add(3600, :second)

      account = put_trial(account, started, ended)

      assert AccountAccess.eligible?(account, started),
             "now == trial_started_at must be eligible (start inclusive)"
    end
  end

  describe "eligible?/2 — entitlement lifecycle" do
    test "Account with active, unexpired entitlement is eligible", %{account: account} do
      now = DateTime.utc_now()

      insert_entitlement!(account,
        is_active: true,
        expiration_date: DateTime.add(now, 3600, :second)
      )

      account = reload_account!(account.id)

      assert AccountAccess.eligible?(account, now)
    end

    test "Account with active entitlement in grace period remains eligible", %{account: account} do
      now = DateTime.utc_now()

      insert_entitlement!(account,
        is_active: true,
        expiration_date: DateTime.add(now, -3600, :second),
        grace_period_expires_date: DateTime.add(now, 3600, :second)
      )

      account = reload_account!(account.id)

      assert AccountAccess.eligible?(account, now)
    end

    test "Account with only inactive entitlements is NOT eligible", %{account: account} do
      now = DateTime.utc_now()

      insert_entitlement!(account,
        is_active: false,
        expiration_date: DateTime.add(now, 86_400, :second)
      )

      account = reload_account!(account.id)

      refute AccountAccess.eligible?(account, now)
    end

    test "Account with expired entitlement and expired grace is NOT eligible", %{account: account} do
      now = DateTime.utc_now()

      insert_entitlement!(account,
        is_active: true,
        expiration_date: DateTime.add(now, -86_400, :second),
        grace_period_expires_date: DateTime.add(now, -3600, :second)
      )

      account = reload_account!(account.id)

      refute AccountAccess.eligible?(account, now)
    end

    test "Active entitlement with nil expiration/grace (lifetime grant) is eligible",
         %{account: account} do
      now = DateTime.utc_now()

      insert_entitlement!(account,
        is_active: true,
        expiration_date: nil,
        grace_period_expires_date: nil
      )

      account = reload_account!(account.id)

      assert AccountAccess.eligible?(account, now)
    end
  end

  describe "eligible?/2 — trial OR entitlement (union semantics)" do
    test "Account with expired trial but active entitlement is eligible", %{account: account} do
      now = DateTime.utc_now()

      account =
        put_trial(
          account,
          DateTime.add(now, -10 * 86_400, :second),
          DateTime.add(now, -3600, :second)
        )

      insert_entitlement!(account,
        is_active: true,
        expiration_date: DateTime.add(now, 86_400, :second)
      )

      account = reload_account!(account.id)

      assert AccountAccess.eligible?(account, now)
    end

    test "Account with active trial and inactive entitlement is eligible", %{account: account} do
      now = DateTime.utc_now()

      account =
        put_trial(
          account,
          DateTime.add(now, -3600, :second),
          DateTime.add(now, 86_400, :second)
        )

      insert_entitlement!(account,
        is_active: false,
        expiration_date: DateTime.add(now, 86_400, :second)
      )

      account = reload_account!(account.id)

      assert AccountAccess.eligible?(account, now)
    end
  end

  describe "status/2 — structured status payload" do
    test "returns :expired with source :trial when trial ended", %{account: account} do
      started = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second)
      ended = DateTime.utc_now() |> DateTime.add(-3600, :second)

      account = put_trial(account, started, ended)
      now = DateTime.utc_now()

      status = AccountAccess.status(account, now)

      assert status.state == :expired
      assert status.source == :trial
      assert status.trial_started_at == started
      assert status.trial_ends_at == ended
    end

    test "returns :trial when trial covers now", %{account: account} do
      started = DateTime.utc_now() |> DateTime.add(-3600, :second)
      ended = DateTime.utc_now() |> DateTime.add(86_400, :second)

      account = put_trial(account, started, ended)
      now = DateTime.utc_now()

      status = AccountAccess.status(account, now)

      assert status.state == :trial
      assert status.source == :trial
    end

    test "returns :active with source :entitlement when entitlement covers now", %{
      account: account
    } do
      now = DateTime.utc_now()

      insert_entitlement!(account,
        is_active: true,
        expiration_date: DateTime.add(now, 86_400, :second)
      )

      account = reload_account!(account.id)

      status = AccountAccess.status(account, now)

      assert status.state == :active
      assert status.source == :entitlement
    end

    test "returns :expired with source :none when no trial and no entitlement",
         %{account: account, now: now} do
      status = AccountAccess.status(account, now)

      assert status.state == :expired
      assert status.source == :none
      assert is_nil(status.trial_started_at)
      assert is_nil(status.trial_ends_at)
    end
  end

  describe "Account data retention after eligibility is lost" do
    test "Account membership, entitlements and the Account row survive after expiry",
         %{account: account, user: user} do
      now = DateTime.utc_now()
      account = put_trial(account, DateTime.add(now, -86_400, :second), now)

      entitlement =
        insert_entitlement!(account,
          is_active: true,
          expiration_date: now
        )

      assert Repo.get_by!(AccountMembership, user_id: user.id, account_id: account.id)

      after_expiry = DateTime.add(now, 3600, :second)
      refute AccountAccess.eligible?(account, after_expiry)

      # Nothing was deleted as a side effect of expiry.
      assert Repo.get!(PersistenceAccount, account.id)
      assert Repo.get!(PersistenceUser, user.id)
      assert Repo.get_by!(AccountMembership, user_id: user.id, account_id: account.id)
      assert Repo.get!(RevenuecatEntitlement, entitlement.id)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp insert_account_and_owner! do
    {:ok, account} =
      %PersistenceAccount{}
      |> PersistenceAccount.changeset(%{
        name: "Access Test #{Ecto.UUID.generate()}",
        plan: :individual,
        default_budget_cents: 0
      })
      |> Repo.insert()

    {:ok, user} =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{
        account_id: account.id,
        email: "u_access_#{Ecto.UUID.generate()}@example.com",
        name: "Owner",
        role: :owner
      })
      |> Repo.insert()

    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account.id,
      user_id: user.id,
      role: :owner,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    %{account: account, user: user}
  end

  defp put_trial(account, started_at, ends_at) do
    {:ok, updated} =
      account
      |> PersistenceAccount.changeset(%{
        trial_started_at: started_at,
        trial_ends_at: ends_at
      })
      |> Repo.update()

    updated
  end

  defp insert_entitlement!(account, attrs) do
    base = %{
      account_id: account.id,
      rc_app_user_id: "rc_app_#{Ecto.UUID.generate()}",
      entitlement_id: "pro",
      product_identifier: "premium_monthly",
      is_active: true,
      will_renew: false,
      store: "app_store",
      raw_payload: %{}
    }

    %RevenuecatEntitlement{}
    |> RevenuecatEntitlement.changeset(Map.merge(base, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp reload_account!(account_id) do
    account = Repo.get!(PersistenceAccount, account_id)
    Repo.preload(account, [:revenuecat_entitlements])
  end
end
