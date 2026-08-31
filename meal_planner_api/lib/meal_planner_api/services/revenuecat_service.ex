defmodule MealPlannerApi.Services.RevenuecatService do
  @moduledoc """
  RevenueCat integration service.
  Wraps Revenuecat module logic.
  """

  import Ecto.Query, only: [from: 2]

  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.Integrations.RevenuecatWebhook
  alias MealPlannerApi.Persistence.Accounts
  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.RevenuecatWebhookEvent
  alias MealPlannerApi.Repo

  @doc """
  Ingest a signed RevenueCat webhook from its EXACT raw bytes.

  This is the only path allowed to change Account eligibility
  (`revenuecat-access-enforcement`). The signature is verified before
  decoding, every event is durably recorded in the ledger, and the
  application is serialized under an Account row lock so that only
  strictly newer provider timestamps change state.

  Returns `{:ok, %{status: "processed" | "duplicate" | "stale" | "ignored"}}`
  or `{:error, :invalid_webhook_signature | :invalid_webhook_payload}`.
  """
  @spec ingest_webhook(binary(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def ingest_webhook(raw_body, signature_header) when is_binary(raw_body) do
    secret = Application.get_env(:meal_planner_api, :revenuecat_webhook_signing_secret)

    with :ok <- RevenuecatWebhook.verify(raw_body, signature_header, secret),
         {:ok, event} <- RevenuecatWebhook.normalize(raw_body) do
      record_and_apply(event)
    end
  end

  @spec resolve_tier(Ecto.UUID.t(), :free | :premium) :: :free | :premium
  def resolve_tier(account_id, fallback_tier \\ :free) when is_binary(account_id) do
    entitlements = Accounts.list_active_revenuecat_entitlements_for_account(account_id)

    if entitlements == [] do
      fallback_tier
    else
      :premium
    end
  end

  # -------------------------------------------------------------------------
  # RevenueCat entitlement management
  # -------------------------------------------------------------------------

  @spec link_test_entitlement(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def link_test_entitlement(account_id) do
    now = DateTime.utc_now()
    expiration = DateTime.add(now, 7 * 24 * 3600, :second)

    attrs = %{
      account_id: account_id,
      entitlement_id: "test_entitlement",
      status: "active",
      period_type: "test",
      purchase_date: now,
      expiration_date: expiration,
      store: "test_store",
      event_id: "test_event_#{DateTime.to_unix(now)}"
    }

    Accounts.upsert_revenuecat_entitlement(attrs)
  end

  @spec activate_premium_entitlement(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def activate_premium_entitlement(account_id) do
    now = DateTime.utc_now()
    # 1 year expiration for premium
    expiration = DateTime.add(now, 365 * 24 * 3600, :second)

    attrs = %{
      account_id: account_id,
      entitlement_id: "premium",
      status: "active",
      period_type: "normal",
      purchase_date: now,
      expiration_date: expiration,
      store: "app_store",
      event_id: "purchase_event_#{DateTime.to_unix(now)}"
    }

    Accounts.upsert_revenuecat_entitlement(attrs)
  end

  @spec deactivate_premium_entitlement(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def deactivate_premium_entitlement(account_id) do
    now = DateTime.utc_now()

    attrs = %{
      account_id: account_id,
      entitlement_id: "premium",
      status: "inactive",
      period_type: "normal",
      purchase_date: now,
      expiration_date: now,
      store: "app_store",
      event_id: "cancellation_event_#{DateTime.to_unix(now)}"
    }

    Accounts.upsert_revenuecat_entitlement(attrs)
  end

  # -------------------------------------------------------------------------
  # Signed webhook ingestion (revenuecat-access-enforcement, PR 2)
  # -------------------------------------------------------------------------

  defp record_and_apply(event) do
    account_id = linked_account_id(event.rc_app_user_id)

    case upsert_ledger_entry(event, account_id) do
      {:duplicate, _status} ->
        {:ok, %{event_id: event.event_id, status: "duplicate"}}

      {:ok, ledger_entry} ->
        apply_ledger_entry(ledger_entry, event, account_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_ledger_entry(ledger_entry, event, nil) do
    ignore(ledger_entry, event, "unlinked_account")
  end

  defp apply_ledger_entry(ledger_entry, event, account_id) do
    if RevenuecatWebhook.known_type?(event.event_type) do
      Repo.transaction(fn -> apply_locked(ledger_entry, event, account_id) end)
    else
      ignore(ledger_entry, event, "unhandled_event_type")
    end
  end

  defp apply_locked(ledger_entry, event, account_id) do
    account =
      from(a in Account, where: a.id == ^account_id, lock: "FOR UPDATE")
      |> Repo.one!()

    if newer?(event.provider_event_at, account.latest_provider_event_at) do
      :ok = apply_entitlement(account, event)
      :ok = apply_account_state(account, event)
      mark(ledger_entry, :processed, account_id)
      %{event_id: event.event_id, status: "processed"}
    else
      mark(ledger_entry, :ignored, account_id)
      %{event_id: event.event_id, status: "stale"}
    end
  end

  defp apply_entitlement(account, event) do
    expired? = event.event_type == "EXPIRATION"

    {:ok, _} =
      Accounts.upsert_revenuecat_entitlement(%{
        account_id: account.id,
        rc_app_user_id: event.rc_app_user_id,
        entitlement_id: event.entitlement_id,
        product_identifier: event.product_identifier,
        is_active: not expired?,
        will_renew: RevenuecatWebhook.grant_type?(event.event_type),
        store: event.store,
        purchase_date: event.provider_event_at,
        expiration_date: if(expired?, do: event.provider_event_at, else: event.expiration_date),
        grace_period_expires_date: event.grace_period_expires_date,
        raw_payload: event.payload
      })

    :ok
  end

  defp apply_account_state(account, event) do
    attrs =
      %{latest_provider_event_at: event.provider_event_at}
      |> Map.merge(trial_attrs(account, event))

    {:ok, _} = account |> Account.changeset(attrs) |> Repo.update()
    :ok
  end

  # The one-time trial starts at the FIRST qualifying provider event and is
  # never restarted by later renewals.
  defp trial_attrs(%Account{trial_started_at: nil} = _account, event) do
    if RevenuecatWebhook.qualifying_trial_type?(event.event_type) do
      window = AccountAccess.trial_window(event.provider_event_at)
      %{trial_started_at: window.started_at, trial_ends_at: window.ends_at}
    else
      %{}
    end
  end

  defp trial_attrs(_account, _event), do: %{}

  defp linked_account_id(rc_app_user_id) do
    case Accounts.get_revenuecat_customer_by_app_user_id(rc_app_user_id) do
      nil -> nil
      customer -> customer.account_id
    end
  end

  # Insert the ledger entry first so retries are durable. A known event ID
  # that already reached a terminal status is a duplicate; `received`/`failed`
  # entries are retryable and reused.
  #
  # `Repo.get_by` followed by `Repo.insert` is non-atomic; under concurrent
  # retries for the same `event_id` the unique index raises an
  # `Ecto.Constraints.UniqueViolationError` on the racing inserter. We
  # swallow that and re-fetch the row so every caller observes a single
  # ledger entry plus a `{:duplicate, _}` outcome (consistent with the
  # serial path) instead of a crash.
  defp upsert_ledger_entry(event, account_id) do
    attrs = %{
      event_id: event.event_id,
      event_type: event.event_type,
      rc_app_user_id: event.rc_app_user_id,
      account_id: account_id,
      status: :received,
      received_at: DateTime.utc_now(),
      provider_event_at: event.provider_event_at,
      payload: event.payload
    }

    case Repo.get_by(RevenuecatWebhookEvent, event_id: event.event_id) do
      nil ->
        case Accounts.create_revenuecat_webhook_event(attrs) do
          {:ok, entry} ->
            {:ok, entry}

          {:error, %Ecto.Changeset{} = changeset} ->
            if unique_violation?(changeset) do
              recover_racing_insert(event)
            else
              {:error, changeset}
            end
        end

      %RevenuecatWebhookEvent{status: status} when status in [:processed, :ignored] ->
        {:duplicate, status}

      existing ->
        Accounts.update_revenuecat_webhook_event(existing, attrs)
    end
  end

  defp recover_racing_insert(event) do
    case Repo.get_by(RevenuecatWebhookEvent, event_id: event.event_id) do
      %RevenuecatWebhookEvent{status: status} when status in [:processed, :ignored] ->
        {:duplicate, status}

      %RevenuecatWebhookEvent{} = row ->
        {:ok, row}

      nil ->
        {:error, :ledger_insert_race_lost_row}
    end
  end

  defp unique_violation?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp ignore(ledger_entry, event, reason) do
    mark(ledger_entry, :ignored, ledger_entry.account_id, reason)
    {:ok, %{event_id: event.event_id, status: "ignored", reason: reason}}
  end

  defp mark(ledger_entry, status, account_id, error_message \\ nil) do
    {:ok, _} =
      Accounts.update_revenuecat_webhook_event(ledger_entry, %{
        status: status,
        account_id: account_id,
        processed_at: DateTime.utc_now(),
        error_message: error_message
      })

    :ok
  end

  defp newer?(%DateTime{}, nil), do: true

  defp newer?(%DateTime{} = candidate, %DateTime{} = applied),
    do: DateTime.compare(candidate, applied) == :gt
end
