defmodule MealPlannerApi.Revenuecat do
  @moduledoc """
  RevenueCat integration layer using existing persistence tables.
  """

  alias MealPlannerApi.Persistence.Accounts

  @spec resolve_tier(Ecto.UUID.t(), atom()) :: :free | :premium
  def resolve_tier(account_id, fallback_tier \\ :free) when is_binary(account_id) do
    entitlements = Accounts.list_active_revenuecat_entitlements_for_account(account_id)

    if entitlements == [] do
      normalize_tier(fallback_tier)
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

      {:ok, event_row} =
        Accounts.create_revenuecat_webhook_event(%{
          event_id: event_id,
          event_type: event_type,
          rc_app_user_id: rc_app_user_id,
          account_id: account_id,
          status: :received,
          received_at: DateTime.utc_now(),
          payload: payload
        })

      result =
        if account_id do
          sync_entitlements(
            account_id,
            rc_app_user_id,
            Map.get(payload, "entitlements", []),
            event_id
          )
        else
          {:ok, %{processed_entitlements: 0, tier: "free"}}
        end

      case result do
        {:ok, data} ->
          {:ok, _} =
            Accounts.update_revenuecat_webhook_event(event_row, %{
              status: :processed,
              processed_at: DateTime.utc_now()
            })

          {:ok, Map.merge(%{event_id: event_id, event_type: event_type}, data)}

        {:error, reason} ->
          {:ok, _} =
            Accounts.update_revenuecat_webhook_event(event_row, %{
              status: :failed,
              processed_at: DateTime.utc_now(),
              error_message: serialize_reason(reason)
            })

          {:error, reason}
      end
    end
  end

  @spec sync_entitlements_from_app(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def sync_entitlements_from_app(account_id, user_id, payload)
      when is_binary(account_id) and is_binary(user_id) and is_map(payload) do
    with {:ok, rc_app_user_id} <- require_binary(Map.get(payload, "rc_app_user_id")),
         {:ok, _customer} <-
           Accounts.upsert_revenuecat_customer(%{
             account_id: account_id,
             user_id: user_id,
             rc_app_user_id: rc_app_user_id
           }) do
      sync_entitlements(
        account_id,
        rc_app_user_id,
        Map.get(payload, "entitlements", []),
        Map.get(payload, "event_id")
      )
    end
  end

  defp sync_entitlements(account_id, rc_app_user_id, entitlements, event_id)
       when is_list(entitlements) do
    now = DateTime.utc_now()

    count =
      Enum.reduce(entitlements, 0, fn entitlement, acc ->
        entitlement_id = Map.get(entitlement, "entitlement_id") || Map.get(entitlement, "id")

        if is_binary(entitlement_id) do
          _ =
            Accounts.upsert_revenuecat_entitlement(%{
              account_id: account_id,
              rc_app_user_id: rc_app_user_id,
              entitlement_id: entitlement_id,
              product_identifier: Map.get(entitlement, "product_identifier"),
              is_active: Map.get(entitlement, "is_active", false),
              will_renew: Map.get(entitlement, "will_renew"),
              store: Map.get(entitlement, "store"),
              purchase_date: parse_dt(Map.get(entitlement, "purchase_date")),
              expiration_date: parse_dt(Map.get(entitlement, "expiration_date")),
              grace_period_expires_date:
                parse_dt(Map.get(entitlement, "grace_period_expires_date")),
              raw_payload: entitlement
            })

          _ =
            Accounts.create_revenuecat_subscription_snapshot(%{
              account_id: account_id,
              rc_app_user_id: rc_app_user_id,
              product_identifier: Map.get(entitlement, "product_identifier") || "unknown",
              entitlement_id: entitlement_id,
              status:
                if(Map.get(entitlement, "is_active", false), do: "active", else: "inactive"),
              period_type: Map.get(entitlement, "period_type"),
              purchase_date: parse_dt(Map.get(entitlement, "purchase_date")),
              expiration_date: parse_dt(Map.get(entitlement, "expiration_date")),
              store: Map.get(entitlement, "store"),
              event_id: event_id
            })

          acc + 1
        else
          acc
        end
      end)

    tier = resolve_tier(account_id, :free)

    {:ok,
     %{
       rc_app_user_id: rc_app_user_id,
       processed_entitlements: count,
       tier: Atom.to_string(tier),
       synced_at: DateTime.to_iso8601(now)
     }}
  end

  defp sync_entitlements(_account_id, _rc_app_user_id, _entitlements, _event_id),
    do: {:error, :invalid_entitlements_payload}

  defp extract_event(%{"event" => event}) when is_map(event), do: {:ok, event}
  defp extract_event(payload) when is_map(payload), do: {:ok, payload}

  defp validate_webhook_secret(headers) do
    expected = System.get_env("REVENUECAT_WEBHOOK_SECRET")

    if is_nil(expected) or expected == "" do
      :ok
    else
      provided = Map.get(headers, "authorization") || Map.get(headers, "x-revenuecat-signature")

      valid? =
        provided == expected or provided == "Bearer " <> expected or
          String.trim(to_string(provided || "")) == expected

      if valid?, do: :ok, else: {:error, :invalid_webhook_secret}
    end
  end

  defp require_binary(value) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_), do: {:error, :invalid_payload}

  defp parse_dt(nil), do: nil

  defp parse_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp normalize_tier(:premium), do: :premium
  defp normalize_tier("premium"), do: :premium
  defp normalize_tier(_), do: :free

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"
end
