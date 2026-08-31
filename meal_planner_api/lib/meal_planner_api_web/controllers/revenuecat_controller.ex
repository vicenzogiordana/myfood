defmodule MealPlannerApiWeb.RevenuecatController do
  @moduledoc """
  RevenueCat HTTP boundary (`revenuecat-access-enforcement`, PR 3).

  Four actions, each with a strict contract from
  `design.md` §"Interfaces / Contracts":

    * `webhook/2` — signed, raw-bytes ingestion. The only path allowed
      to change Account eligibility. Auth is unauthenticated by design
      (RevenueCat calls it directly); ownership is verified from the
      webhook payload itself.
    * `status/2` — GET, returns Account-wide eligibility + a
      server-issued Account-scoped `app_user_id` so all members of the
      Account know what to pass to `Purchases.logIn`. Works for both
      eligible and expired Accounts (recovery route).
    * `purchase/2` / `restore/2` — POST, payloadless. Confirms the
      current server state after the React Native SDK has completed
      the store-side flow. Returns `200` with the current state, or
      `202 {"state":"pending_webhook"}` when no webhook has yet
      granted eligibility. Any entitlement/receipt input on these
      routes is `422 client_entitlement_grant_forbidden` — only a
      validated webhook may ever grant eligibility.

  The previous client `sync/2` endpoint has been DELETED. The legacy
  `RevenuecatService.process_webhook/2` and
  `RevenuecatService.sync_entitlements/3` were removed in PR 3 task
  3.4 alongside this rewrite.
  """

  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.Persistence.Accounts, as: AccountsPersistence
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.RevenuecatService

  # Per `design.md` §"Interfaces / Contracts": any of these keys on a
  # recovery-route request body means the client is trying to grant
  # itself eligibility. The contract is enforced BEFORE the recovery
  # logic runs — only a signed webhook can ever grant state.
  @client_grant_keys ~w(
    entitlements
    entitlement_id
    entitlement_ids
    product_identifier
    purchase_date
    expiration_date
    expiration_at_ms
    receipt
    customer_info
    store
    will_renew
    is_active
  )

  # Webhook response shapes — kept here so all branches share the same
  # JSON envelope (`data: %{status: ..., event_id: ..., reason?: ...}`).
  @webhook_success_statuses ~w(processed duplicate stale ignored)

  # ─── Webhook ────────────────────────────────────────────────────────────

  def webhook(conn, _params) do
    raw_body = Map.get(conn.assigns, :raw_body)

    signature_header =
      conn.req_headers
      |> Enum.into(%{}, fn {k, v} -> {String.downcase(k), v} end)
      |> Map.get("x-revenuecat-webhook-signature")

    case RevenuecatService.ingest_webhook(raw_body, signature_header) do
      {:ok, %{status: status} = result} when status in @webhook_success_statuses ->
        json(conn, %{data: Map.take(result, [:status, :event_id, :reason])})

      {:error, :invalid_webhook_signature} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_webhook_signature"})

      {:error, :invalid_webhook_payload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_webhook_payload"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "webhook_processing_failed", reason: inspect(reason)})
    end
  end

  # ─── Recovery routes (auth + capability-exempt) ────────────────────────

  def status(conn, params), do: respond_recovery(conn, params, &status_payload/1)

  def purchase(conn, params), do: respond_recovery(conn, params, &purchase_restore_payload/1)

  def restore(conn, params), do: respond_recovery(conn, params, &purchase_restore_payload/1)

  # Shared envelope: detect client grant attempts first, then dispatch to
  # the route-specific payload builder.
  defp respond_recovery(conn, params, payload_builder) do
    if client_grant_payload?(params) do
      forbid_client_grant(conn)
    else
      payload = payload_builder.(conn)
      render_recovery(conn, payload)
    end
  end

  defp render_recovery(conn, %{http_status: status} = payload) do
    conn
    |> put_status(status)
    |> json(%{data: Map.delete(payload, :http_status)})
  end

  # ─── Payload builders ──────────────────────────────────────────────────

  defp status_payload(conn) do
    account = load_current_account(conn)

    case account do
      nil ->
        %{
          http_status: 200,
          state: "expired",
          source: "none",
          trial_started_at: nil,
          trial_ends_at: nil,
          latest_provider_event_at: nil,
          app_user_id: nil
        }

      %PersistenceAccount{} ->
        status = AccountAccess.status(account, DateTime.utc_now())

        %{
          http_status: 200,
          state: Atom.to_string(status.state),
          source: Atom.to_string(status.source),
          trial_started_at: iso(status.trial_started_at),
          trial_ends_at: iso(status.trial_ends_at),
          latest_provider_event_at: iso(status.latest_provider_event_at),
          app_user_id: app_user_id_for_account(account.id)
        }
    end
  end

  defp purchase_restore_payload(conn) do
    account = load_current_account(conn)

    case account do
      nil ->
        pending_webhook_payload()

      %PersistenceAccount{} ->
        now = DateTime.utc_now()

        if AccountAccess.eligible?(account, now) do
          status = AccountAccess.status(account, now)

          %{
            http_status: 200,
            state: Atom.to_string(status.state),
            source: Atom.to_string(status.source)
          }
        else
          pending_webhook_payload()
        end
    end
  end

  defp pending_webhook_payload do
    %{http_status: 202, state: "pending_webhook"}
  end

  # ─── Predicates / DB helpers ───────────────────────────────────────────

  defp client_grant_payload?(params) when is_map(params) do
    Enum.any?(@client_grant_keys, &Map.has_key?(params, &1))
  end

  defp client_grant_payload?(_), do: false

  defp forbid_client_grant(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "client_entitlement_grant_forbidden"})
  end

  defp load_current_account(conn) do
    case conn.assigns[:current_membership] do
      %{account_id: account_id} when not is_nil(account_id) ->
        case Ecto.UUID.cast(account_id) do
          {:ok, uuid} -> load_account_with_entitlements(uuid)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp load_account_with_entitlements(account_id) do
    PersistenceAccount
    |> Repo.get(account_id)
    |> case do
      nil -> nil
      account -> Repo.preload(account, :revenuecat_entitlements)
    end
  end

  # The Account's `app_user_id` is server-issued and stored on the
  # `RevenuecatCustomer` row (PR 1). All members of an Account share the
  # same `app_user_id`; account switching logs into the new one.
  defp app_user_id_for_account(account_id) do
    case AccountsPersistence.get_revenuecat_customer_by_account_id(account_id) do
      nil -> nil
      customer -> customer.rc_app_user_id
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
