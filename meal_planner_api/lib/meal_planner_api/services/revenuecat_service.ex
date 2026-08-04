defmodule MealPlannerApi.Services.RevenuecatService do
  @moduledoc """
  RevenueCat integration service.
  Wraps Revenuecat module logic.
  """

  alias MealPlannerApi.Persistence.Accounts

  @spec resolve_tier(Ecto.UUID.t(), :free | :premium) :: :free | :premium
  def resolve_tier(account_id, fallback_tier \\ :free) when is_binary(account_id) do
    entitlements = Accounts.list_active_revenuecat_entitlements_for_account(account_id)

    if entitlements == [] do
      fallback_tier
    else
      :premium
    end
  end

  @spec process_webhook(map(), map()) :: {:ok, map()} | {:error, term()}
  def process_webhook(payload, headers) when is_map(payload) and is_map(headers) do
    with :ok <- validate_webhook_secret(headers),
         {:ok, event} <- extract_event(payload),
         {:ok, event_id} <- require_binary(Map.get(event, "id") || Map.get(payload, "event_id")),
         {:ok, event_type} <-
           require_binary(Map.get(event, "type") || Map.get(payload, "event_type") || "unknown"),
         {:ok, rc_app_user_id} <-
           require_binary(Map.get(event, "app_user_id") || Map.get(payload, "rc_app_user_id")) do
      account_id =
        case Accounts.get_revenuecat_customer_by_app_user_id(rc_app_user_id) do
          nil -> nil
          customer -> customer.account_id
        end

      if account_id do
        {:ok, result} = handle_rc_event(event_type, account_id, event)
        {:ok, Map.put(result, :event_id, event_id)}
      else
        {:ok, %{event_id: event_id, status: "ignored", reason: "unlinked_account"}}
      end
    end
  end

  def sync_entitlements(account_id, _user_id, payload)
      when is_binary(account_id) and is_map(payload) do
    rc_app_user_id = Map.get(payload, "rc_app_user_id")

    if is_binary(rc_app_user_id) do
      attrs = %{account_id: account_id, rc_app_user_id: rc_app_user_id}

      case Accounts.upsert_revenuecat_customer(attrs) do
        {:ok, _} ->
          # Process entitlements from payload
          entitlements = Map.get(payload, "entitlements", [])
          processed = Enum.count(entitlements)

          # Upsert entitlements and determine tier
          tier =
            case entitlements do
              [] ->
                :free

              _ ->
                Enum.each(entitlements, fn ent ->
                  attrs = %{
                    account_id: account_id,
                    rc_app_user_id: rc_app_user_id,
                    entitlement_id: Map.get(ent, "entitlement_id", "unknown"),
                    product_identifier: Map.get(ent, "product_identifier"),
                    is_active: Map.get(ent, "is_active", false),
                    will_renew: Map.get(ent, "will_renew", false),
                    store: Map.get(ent, "store", "unknown"),
                    raw_payload: ent,
                    purchase_date:
                      case Map.get(ent, "purchase_date") do
                        nil ->
                          nil

                        d when is_binary(d) ->
                          case DateTime.from_iso8601(d) do
                            {:ok, dt, _} -> dt
                            {:error, _} -> DateTime.utc_now()
                          end

                        d ->
                          d
                      end,
                    expiration_date:
                      case Map.get(ent, "expiration_date") do
                        nil ->
                          nil

                        d when is_binary(d) ->
                          case DateTime.from_iso8601(d) do
                            {:ok, dt, _} -> dt
                            {:error, _} -> nil
                          end

                        d ->
                          d
                      end
                  }

                  Accounts.upsert_revenuecat_entitlement(attrs)
                end)

                has_active_pro =
                  Enum.any?(entitlements, fn e ->
                    Map.get(e, "entitlement_id") == "pro" && Map.get(e, "is_active", false)
                  end)

                if has_active_pro, do: :premium, else: :free
            end

          {:ok, %{processed_entitlements: processed, tier: Atom.to_string(tier)}}

        {:error, _} = err ->
          err
      end
    else
      {:error, :missing_rc_app_user_id}
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
  # Private helpers (migrated from revenuecat.ex)
  # -------------------------------------------------------------------------

  defp validate_webhook_secret(headers) do
    secret = Application.get_env(:meal_planner_api, :revenuecat_webhook_secret)

    if is_binary(secret) and secret != "" do
      received =
        Map.get(headers, "authorization") ||
          Map.get(headers, "x-revenuecat-signature", "")

      if received == secret or received == "Bearer " <> secret do
        :ok
      else
        {:error, :invalid_webhook_secret}
      end
    else
      :ok
    end
  end

  defp extract_event(payload) do
    case Map.get(payload, "event") do
      event when is_map(event) -> {:ok, event}
      nil -> {:ok, payload}
    end
  end

  defp require_binary(nil), do: {:error, :missing_required_field}
  defp require_binary(val) when is_binary(val), do: {:ok, val}
  defp require_binary(_), do: {:error, :invalid_required_field}

  defp handle_rc_event("TEST", account_id, _event) do
    link_test_entitlement(account_id)
    {:ok, %{status: "test_received", processed_entitlements: 1}}
  end

  defp handle_rc_event("INITIAL_PURCHASE", account_id, _event) do
    activate_premium_entitlement(account_id)
    {:ok, %{status: "premium_activated", processed_entitlements: 1}}
  end

  defp handle_rc_event("RENEWAL", account_id, _event) do
    activate_premium_entitlement(account_id)
    {:ok, %{status: "premium_renewed", processed_entitlements: 1}}
  end

  defp handle_rc_event("CANCELLATION", account_id, _event) do
    deactivate_premium_entitlement(account_id)
    {:ok, %{status: "premium_deactivated", processed_entitlements: 1}}
  end

  defp handle_rc_event(_type, _account_id, _event) do
    {:ok, %{status: "ignored", reason: "unhandled_event_type", processed_entitlements: 0}}
  end
end
