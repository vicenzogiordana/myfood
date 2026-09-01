defmodule MealPlannerApi.Repo.Migrations.AddRevenuecatAccessState do
  @moduledoc """
  PR 1 / Phase 1 of `revenuecat-access-enforcement`.

  Adds Account-level access state and a required provider-event timestamp on
  the webhook ledger:

  * `accounts.trial_started_at`, `accounts.trial_ends_at` — set ONCE by the
    first qualifying RevenueCat purchase / trial event. Nullable for the
    pre-trial window. Spec: "One-Time Trial Lifecycle".
  * `accounts.latest_provider_event_at` — the provider-supplied timestamp of
    the most recent applied webhook. Ordering gate for the locked ledger
    apply (Phase 2 / PR 2). Nullable so legacy Accounts continue to insert.
  * `revenuecat_webhook_events.provider_event_at` — REQUIRED provider
    timestamp on every recorded event; the apply gate compares it against
    `accounts.latest_provider_event_at`.

  Nullable columns let the existing rows ship unchanged; the change ships
  with enforcement disabled (`REVENUECAT_ACCESS_ENFORCEMENT` off, Phase 2
  config wiring) so the migration can be applied safely.
  """

  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:trial_started_at, :utc_datetime_usec, null: true)
      add(:trial_ends_at, :utc_datetime_usec, null: true)
      add(:latest_provider_event_at, :utc_datetime_usec, null: true)
    end

    # Cheap guard against a half-open window being persisted backwards
    # (trial_ends_at < trial_started_at) by future code paths. NOT a
    # substitute for the application-level guarantee — it's there to fail
    # loud during development, not to model the boundary-time semantic
    # (which is enforced by `MealPlannerApi.AccountAccess`).
    create constraint(:accounts, :accounts_trial_window_check,
             check: "trial_started_at IS NULL OR trial_ends_at IS NULL OR trial_ends_at >= trial_started_at"
           )

    alter table(:revenuecat_webhook_events) do
      add(:provider_event_at, :utc_datetime_usec, null: false)
    end

    create index(:revenuecat_webhook_events, [:provider_event_at])
  end
end
