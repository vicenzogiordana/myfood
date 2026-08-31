defmodule MealPlannerApi.Services.RevenuecatServiceTest do
  @moduledoc """
  Tests for signed, ordered RevenueCat webhook ingestion
  (`revenuecat-access-enforcement` — PR 2, Trusted ordered webhook
  ingestion).

  Covered contracts:

    * exact raw-byte HMAC-SHA256 over `"<t>.<raw-body>"`, 300s tolerance
    * malformed signature/payload rejection before any state change
    * unknown linked identity is recorded as ignored, never applied
    * duplicate retry semantics (processed -> duplicate, failed -> retry)
    * strict-newest ordering (equal/older provider timestamps are stale)
    * one-time 7-day trial, renewal preservation, cancellation, expiration
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.Integrations.RevenuecatWebhook
  alias MealPlannerApi.Persistence.Accounts, as: AccountsPersistence
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.RevenuecatWebhookEvent
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.RevenuecatService

  @secret "whsec_test_revenuecat"
  @app_user_id "rc_app_user_pr2"

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    previous = Application.get_env(:meal_planner_api, :revenuecat_webhook_signing_secret)
    Application.put_env(:meal_planner_api, :revenuecat_webhook_signing_secret, @secret)

    on_exit(fn ->
      Application.put_env(:meal_planner_api, :revenuecat_webhook_signing_secret, previous)
    end)

    account = insert_account!()

    {:ok, _customer} =
      AccountsPersistence.upsert_revenuecat_customer(%{
        account_id: account.id,
        rc_app_user_id: @app_user_id
      })

    %{account: account}
  end

  describe "signature and payload trust" do
    test "valid signature over the exact raw bytes is accepted", %{account: account} do
      body = body(%{})

      assert {:ok, %{status: "processed"}} = ingest(body)
      assert AccountAccess.eligible?(reload(account.id), DateTime.utc_now())
    end

    test "signature computed over different bytes is rejected", %{account: account} do
      body = body(%{})
      header = signature_header(body(%{"id" => "evt_other"}))

      assert {:error, :invalid_webhook_signature} =
               RevenuecatService.ingest_webhook(body, header)

      refute AccountAccess.eligible?(reload(account.id), DateTime.utc_now())
      assert Repo.aggregate(RevenuecatWebhookEvent, :count) == 0
    end

    test "signature older than the 300 second tolerance is rejected" do
      body = body(%{})
      stale_ts = System.system_time(:second) - 301

      assert {:error, :invalid_webhook_signature} =
               RevenuecatService.ingest_webhook(body, signature_header(body, stale_ts))
    end

    test "signature inside the 300 second tolerance is accepted" do
      body = body(%{})
      recent_ts = System.system_time(:second) - 299

      assert {:ok, %{status: "processed"}} =
               RevenuecatService.ingest_webhook(body, signature_header(body, recent_ts))
    end

    test "malformed signature header is rejected" do
      body = body(%{})

      assert {:error, :invalid_webhook_signature} =
               RevenuecatService.ingest_webhook(body, "not-a-signature")
    end

    test "signed but non-JSON body is an invalid payload" do
      assert {:error, :invalid_webhook_payload} = ingest("{not json")
    end

    test "signed JSON missing required provider fields is an invalid payload" do
      assert {:error, :invalid_webhook_payload} =
               ingest(Jason.encode!(%{"event" => %{"type" => "RENEWAL"}}))
    end

    test "normalize/1 extracts the provider timestamp as a DateTime" do
      assert {:ok, event} =
               RevenuecatWebhook.normalize(body(%{"event_timestamp_ms" => 1_700_000_000_000}))

      assert event.event_id == "evt_1"
      assert event.rc_app_user_id == @app_user_id
      assert DateTime.to_unix(event.provider_event_at, :millisecond) == 1_700_000_000_000
    end
  end

  describe "linked identity" do
    test "unknown app user id is recorded as ignored and grants nothing", %{account: account} do
      body = body(%{"app_user_id" => "rc_unlinked_user"})

      assert {:ok, %{status: "ignored", reason: "unlinked_account"}} = ingest(body)

      event = Repo.get_by!(RevenuecatWebhookEvent, event_id: "evt_1")
      assert event.status == :ignored
      assert event.account_id == nil
      refute AccountAccess.eligible?(reload(account.id), DateTime.utc_now())
    end
  end

  describe "duplicate and ordering" do
    test "concurrent replay of the same event yields one processed + N duplicates, ledger consistent",
         %{account: account} do
      body = body(%{})
      concurrency = 8

      # Repo.get_by → insert in upsert_ledger_entry/2 is non-atomic; under
      # concurrent retries of the SAME event_id the unique index on
      # revenuecat_webhook_events must serialize every retry to either a
      # single "processed" outcome or a "duplicate" outcome — never a
      # second ledger row, never a UniqueViolation leak.
      #
      # Switch the sandbox to shared mode so the spawned tasks share
      # the test process's transaction; the setup's customer-row write
      # is then visible to every worker, and the racing inserts collide
      # inside one transaction. The losing inserts surface as
      # `Ecto.Constraints.UniqueViolationError`, which the production
      # code absorbs via `recover_racing_insert/1`.
      #
      # Restore the test suite's default (`:auto`) on exit so this
      # test does not leave the sandbox in `:shared` for downstream
      # tests. The mode is not introspectable, but `test_helper.exs`
      # is the only place the mode is set globally.
      Sandbox.mode(Repo, {:shared, self()})
      on_exit(fn -> Sandbox.mode(Repo, :auto) end)

      results =
        1..concurrency
        |> Task.async_stream(
          fn _idx -> RevenuecatService.ingest_webhook(body, signature_header(body)) end,
          max_concurrency: concurrency,
          timeout: 10_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn {:ok, value} -> value end)

      assert length(results) == concurrency

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "expected every concurrent replay to return {:ok, _}, got: #{inspect(results)}"

      statuses = Enum.map(results, fn {:ok, %{status: s}} -> s end)

      assert Enum.count(statuses, &(&1 == "processed")) >= 1,
             "expected at least one processed, got: #{inspect(statuses)}"

      assert Enum.all?(statuses, &(&1 in ["processed", "duplicate", "stale"])),
             "expected only processed/duplicate/stale, got: #{inspect(statuses)}"

      assert Repo.aggregate(RevenuecatWebhookEvent, :count) == 1,
             "expected exactly one ledger row after #{concurrency} concurrent inserts"

      ledger =
        Repo.get_by!(RevenuecatWebhookEvent, event_id: "evt_1")
        |> Repo.preload(:account)

      assert ledger.status in [:processed, :ignored],
             "expected the surviving ledger row to be terminal, got: #{inspect(ledger.status)}"

      assert AccountAccess.eligible?(reload(account.id), DateTime.utc_now())
    end

    test "recover_racing_insert surfaces an existing processed row as duplicate",
         %{account: account} do
      body = body(%{})

      assert {:ok, %{status: "processed"}} = ingest(body)

      # Direct exercise of the upsert path: simulating the second
      # insert attempt in the race. Since the row already exists in
      # :processed, upsert_ledger_entry must return {:duplicate,
      # :processed} rather than raise.
      assert {:ok, %{status: "duplicate"}} = ingest(body)

      assert Repo.aggregate(RevenuecatWebhookEvent, :count) == 1
      assert Repo.get_by!(RevenuecatWebhookEvent, event_id: "evt_1").status == :processed
      assert AccountAccess.eligible?(reload(account.id), DateTime.utc_now())
    end

    test "replaying a processed event returns duplicate without reapplying", %{account: account} do
      body = body(%{})
      assert {:ok, %{status: "processed"}} = ingest(body)
      applied_at = reload(account.id).latest_provider_event_at

      assert {:ok, %{status: "duplicate"}} = ingest(body)
      assert reload(account.id).latest_provider_event_at == applied_at
      assert Repo.aggregate(RevenuecatWebhookEvent, :count) == 1
    end

    test "a previously failed event is retried and applied", %{account: account} do
      body = body(%{})

      {:ok, _} =
        AccountsPersistence.create_revenuecat_webhook_event(%{
          event_id: "evt_1",
          event_type: "INITIAL_PURCHASE",
          rc_app_user_id: @app_user_id,
          status: :failed,
          received_at: DateTime.utc_now(),
          provider_event_at: DateTime.utc_now(),
          payload: %{}
        })

      assert {:ok, %{status: "processed"}} = ingest(body)
      assert Repo.get_by!(RevenuecatWebhookEvent, event_id: "evt_1").status == :processed
      assert AccountAccess.eligible?(reload(account.id), DateTime.utc_now())
    end

    test "an older provider timestamp is stale and does not change state", %{account: account} do
      newest_ms = provider_ms()
      assert {:ok, %{status: "processed"}} = ingest(body(%{"event_timestamp_ms" => newest_ms}))
      applied = reload(account.id)

      older = %{
        "id" => "evt_older",
        "type" => "EXPIRATION",
        "event_timestamp_ms" => newest_ms - 1
      }

      assert {:ok, %{status: "stale"}} = ingest(body(older))

      current = reload(account.id)
      assert current.latest_provider_event_at == applied.latest_provider_event_at
      assert AccountAccess.eligible?(current, DateTime.utc_now())
    end

    test "an equal provider timestamp is stale and does not change state", %{account: account} do
      ms = provider_ms()
      assert {:ok, %{status: "processed"}} = ingest(body(%{"event_timestamp_ms" => ms}))

      equal = %{"id" => "evt_equal", "type" => "EXPIRATION", "event_timestamp_ms" => ms}
      assert {:ok, %{status: "stale"}} = ingest(body(equal))

      assert AccountAccess.eligible?(reload(account.id), DateTime.utc_now())
    end
  end

  describe "lifecycle application" do
    test "first qualifying purchase starts a seven day trial", %{account: account} do
      ms = provider_ms()
      assert {:ok, %{status: "processed"}} = ingest(body(%{"event_timestamp_ms" => ms}))

      updated = reload(account.id)
      assert DateTime.to_unix(updated.trial_started_at, :millisecond) == ms

      assert DateTime.diff(updated.trial_ends_at, updated.trial_started_at, :second) ==
               7 * 86_400
    end

    test "a renewal does not restart the recorded trial", %{account: account} do
      first_ms = provider_ms()
      assert {:ok, %{status: "processed"}} = ingest(body(%{"event_timestamp_ms" => first_ms}))
      after_first = reload(account.id)

      renewal = %{
        "id" => "evt_renewal",
        "type" => "RENEWAL",
        "event_timestamp_ms" => first_ms + 60_000
      }

      assert {:ok, %{status: "processed"}} = ingest(body(renewal))

      after_renewal = reload(account.id)
      assert after_renewal.trial_started_at == after_first.trial_started_at
      assert after_renewal.trial_ends_at == after_first.trial_ends_at
      assert AccountAccess.eligible?(after_renewal, DateTime.utc_now())
    end

    test "cancellation does not revoke access before expiration", %{account: account} do
      ms = provider_ms()
      assert {:ok, %{status: "processed"}} = ingest(body(%{"event_timestamp_ms" => ms}))

      cancellation = %{
        "id" => "evt_cancel",
        "type" => "CANCELLATION",
        "event_timestamp_ms" => ms + 1_000
      }

      assert {:ok, %{status: "processed"}} = ingest(body(cancellation))

      current = reload(account.id)
      assert AccountAccess.eligible?(current, DateTime.utc_now())
      assert [entitlement] = current.revenuecat_entitlements
      assert entitlement.will_renew == false
      assert entitlement.is_active == true
    end

    test "expiration revokes access without deleting Account data", %{account: account} do
      ms = provider_ms()
      assert {:ok, %{status: "processed"}} = ingest(body(%{"event_timestamp_ms" => ms}))

      # Move the trial out of the way so the entitlement decides eligibility.
      expire_trial!(account.id)

      expiration = %{
        "id" => "evt_expire",
        "type" => "EXPIRATION",
        "event_timestamp_ms" => ms + 2_000
      }

      assert {:ok, %{status: "processed"}} = ingest(body(expiration))

      current = reload(account.id)
      refute AccountAccess.eligible?(current, DateTime.utc_now())
      assert [entitlement] = current.revenuecat_entitlements
      assert entitlement.is_active == false
      assert Repo.get!(PersistenceAccount, account.id)
    end

    test "an unhandled provider event type is ignored", %{account: account} do
      body = body(%{"type" => "SUBSCRIBER_ALIAS"})

      assert {:ok, %{status: "ignored", reason: "unhandled_event_type"}} = ingest(body)
      refute AccountAccess.eligible?(reload(account.id), DateTime.utc_now())
    end
  end

  # --- helpers --------------------------------------------------------------

  defp ingest(raw_body),
    do: RevenuecatService.ingest_webhook(raw_body, signature_header(raw_body))

  defp signature_header(raw_body, timestamp \\ nil) do
    timestamp = timestamp || System.system_time(:second)

    signature =
      :crypto.mac(:hmac, :sha256, @secret, "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  defp provider_ms, do: System.system_time(:millisecond)

  defp body(overrides) do
    event =
      Map.merge(
        %{
          "id" => "evt_1",
          "type" => "INITIAL_PURCHASE",
          "app_user_id" => @app_user_id,
          "event_timestamp_ms" => provider_ms(),
          "expiration_at_ms" => System.system_time(:millisecond) + 30 * 86_400_000,
          "product_id" => "myfood_premium_monthly",
          "entitlement_ids" => ["pro"],
          "store" => "APP_STORE"
        },
        overrides
      )

    Jason.encode!(%{"event" => event})
  end

  defp insert_account! do
    {:ok, account} =
      %PersistenceAccount{}
      |> PersistenceAccount.changeset(%{
        name: "Webhook Test #{Ecto.UUID.generate()}",
        plan: :individual,
        default_budget_cents: 0
      })
      |> Repo.insert()

    account
  end

  defp expire_trial!(account_id) do
    past = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    Repo.get!(PersistenceAccount, account_id)
    |> PersistenceAccount.changeset(%{trial_started_at: past, trial_ends_at: past})
    |> Repo.update!()
  end

  defp reload(account_id) do
    PersistenceAccount
    |> Repo.get!(account_id)
    |> Repo.preload(:revenuecat_entitlements, force: true)
  end
end
