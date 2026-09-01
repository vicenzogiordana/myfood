defmodule MealPlannerApi.Integrations.RevenuecatWebhook do
  @moduledoc """
  RevenueCat provider adapter: signature verification and payload
  normalization.

  Trust boundary for `revenuecat-access-enforcement`. The signature is
  verified over the EXACT raw request bytes BEFORE any JSON decoding, so
  a rewritten body can never reach the ledger. Replay is bounded by a
  300-second delivery tolerance.

  Header contract: `X-RevenueCat-Webhook-Signature: t=<unix_s>,v1=<hex>`
  where `v1 = HMAC-SHA256(secret, "<t>.<raw-body>")`.
  """

  @tolerance_seconds 300

  @qualifying_trial_types ~w(INITIAL_PURCHASE NON_RENEWING_PURCHASE)
  @grant_types ~w(INITIAL_PURCHASE NON_RENEWING_PURCHASE RENEWAL UNCANCELLATION PRODUCT_CHANGE)
  @known_types @grant_types ++ ~w(CANCELLATION EXPIRATION)

  @type event :: %{
          event_id: String.t(),
          event_type: String.t(),
          rc_app_user_id: String.t(),
          provider_event_at: DateTime.t(),
          entitlement_id: String.t(),
          product_identifier: String.t() | nil,
          store: String.t() | nil,
          expiration_date: DateTime.t() | nil,
          grace_period_expires_date: DateTime.t() | nil,
          payload: map()
        }

  @doc "Whether the event type may start the one-time trial."
  @spec qualifying_trial_type?(String.t()) :: boolean()
  def qualifying_trial_type?(type), do: type in @qualifying_trial_types

  @doc "Whether the event type grants/keeps an active entitlement."
  @spec grant_type?(String.t()) :: boolean()
  def grant_type?(type), do: type in @grant_types

  @doc "Whether the event type is applied at all."
  @spec known_type?(String.t()) :: boolean()
  def known_type?(type), do: type in @known_types

  @doc """
  Constant-time verification of the signature header over `raw_body`.
  """
  @spec verify(binary(), String.t() | nil, String.t() | nil, integer()) ::
          :ok | {:error, :invalid_webhook_signature}
  def verify(raw_body, header, secret, now_unix \\ System.system_time(:second))

  def verify(raw_body, header, secret, now_unix)
      when is_binary(raw_body) and is_binary(header) and is_binary(secret) and secret != "" do
    with {:ok, timestamp, provided} <- parse_header(header),
         true <- abs(now_unix - timestamp) <= @tolerance_seconds,
         expected <- sign(raw_body, secret, timestamp),
         true <- constant_time_equal?(expected, provided) do
      :ok
    else
      _ -> {:error, :invalid_webhook_signature}
    end
  end

  def verify(_raw_body, _header, _secret, _now_unix), do: {:error, :invalid_webhook_signature}

  @doc "Lowercase hex HMAC-SHA256 over `\"<timestamp>.<raw_body>\"`."
  @spec sign(binary(), String.t(), integer()) :: String.t()
  def sign(raw_body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{raw_body}")
    |> Base.encode16(case: :lower)
  end

  @doc """
  Decode the verified bytes into the normalized provider event.
  """
  @spec normalize(binary()) :: {:ok, event()} | {:error, :invalid_webhook_payload}
  def normalize(raw_body) when is_binary(raw_body) do
    with {:ok, decoded} <- decode(raw_body),
         event when is_map(event) <- Map.get(decoded, "event", decoded),
         {:ok, event_id} <- fetch_string(event, "id"),
         {:ok, event_type} <- fetch_string(event, "type"),
         {:ok, app_user_id} <- fetch_string(event, "app_user_id"),
         {:ok, provider_event_at} <- fetch_timestamp(event, "event_timestamp_ms") do
      {:ok,
       %{
         event_id: event_id,
         event_type: event_type,
         rc_app_user_id: app_user_id,
         provider_event_at: provider_event_at,
         entitlement_id: entitlement_id(event),
         product_identifier: Map.get(event, "product_id"),
         store: Map.get(event, "store"),
         expiration_date: optional_timestamp(event, "expiration_at_ms"),
         grace_period_expires_date: optional_timestamp(event, "grace_period_expiration_at_ms"),
         payload: decoded
       }}
    else
      _ -> {:error, :invalid_webhook_payload}
    end
  end

  def normalize(_raw_body), do: {:error, :invalid_webhook_payload}

  # --- private ---------------------------------------------------------------

  defp parse_header(header) do
    parsed =
      header
      |> String.split(",")
      |> Enum.reduce(%{}, fn part, acc ->
        case String.split(String.trim(part), "=", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    with {:ok, raw_timestamp} <- Map.fetch(parsed, "t"),
         {:ok, signature} <- Map.fetch(parsed, "v1"),
         {timestamp, ""} <- Integer.parse(raw_timestamp) do
      {:ok, timestamp, signature}
    else
      _ -> :error
    end
  end

  defp constant_time_equal?(expected, provided) do
    byte_size(expected) == byte_size(provided) and :crypto.hash_equals(expected, provided)
  end

  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> :error
    end
  end

  defp fetch_string(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_timestamp(event, key) do
    case optional_timestamp(event, key) do
      %DateTime{} = datetime -> {:ok, datetime}
      nil -> :error
    end
  end

  defp optional_timestamp(event, key) do
    case Map.get(event, key) do
      ms when is_integer(ms) -> DateTime.from_unix!(ms, :millisecond)
      _ -> nil
    end
  end

  defp entitlement_id(event) do
    case Map.get(event, "entitlement_ids") do
      [id | _] when is_binary(id) -> id
      _ -> Map.get(event, "entitlement_id") || "default"
    end
  end
end
