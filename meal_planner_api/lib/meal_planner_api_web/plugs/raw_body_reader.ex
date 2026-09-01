defmodule MealPlannerApiWeb.Plugs.RawBodyReader do
  @moduledoc """
  Chunk-safe raw-body reader for the RevenueCat webhook endpoint
  (`revenuecat-access-enforcement`, PR 3 — HTTP capability and recovery).

  The signature is computed over the EXACT bytes of the request body —
  if `Plug.Parsers` parses the body first, JSON normalization (whitespace,
  key ordering, unicode normalization) would invalidate the HMAC. This
  reader reads the raw bytes via `Plug.Conn.read_body/2` and stores them
  in `conn.assigns[:raw_body]` so the controller can pass them straight
  to `RevenuecatService.ingest_webhook/2`.

  Anything NOT a webhook POST is passed through untouched — other
  controllers continue to see parsed params via `Plug.Parsers`.
  """

  @behaviour Plug

  alias Plug.Conn

  @raw_body_threshold 1_000_000
  @webhook_path "/api/billing/revenuecat/webhook"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Conn{method: "POST", request_path: @webhook_path} = conn, _opts) do
    case Conn.read_body(conn, length: @raw_body_threshold) do
      {:ok, raw_body, conn} ->
        Conn.assign(conn, :raw_body, raw_body)

      {:more, _partial, conn} ->
        # Webhook payloads are small; reject anything beyond the threshold
        # rather than silently truncating.
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(413, ~s({"error":"webhook_body_too_large"}))
        |> Conn.halt()

      {:error, reason} ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(400, ~s({"error":"webhook_body_unreadable","reason":"#{reason}"}))
        |> Conn.halt()
    end
  end

  def call(conn, _opts), do: conn
end
