defmodule MealPlannerApiWeb.Plugs.VerifyTokenType do
  @moduledoc """
  Rejects unknown JWT `typ` values during the auth pipeline
  (Phase A — Tenancy Refactor, PR 1 task 1.11).

  Pipeline position: AFTER `Guardian.Plug.VerifyHeader` and BEFORE
  `Guardian.Plug.EnsureAuthenticated`. VerifyHeader validates the
  signature and standard claims; this plug inspects
  `conn.private.guardian_default_claims["typ"]` and either:
    * `"access"` → passes through (legacy `access_v1` token)
    * `"access_v2"` → passes through (new Phase A token)
    * anything else → halts with `401 unauthorized,
      reason: "unsupported_token_type"`

  By keeping this in a separate plug we avoid the Guardian
  VerifyHeader limitation that `claims: %{"typ" => "access"}` only
  accepts ONE typ value. The pipeline now accepts both cutover
  tokens (decision 5.1 / 5.5 / design §4.2) without a forced
  re-login.
  """

  @behaviour Plug

  @supported_typs ~w(access access_v2)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    claims =
      conn.private[:guardian_default_claims] ||
        conn.assigns[:guardian_default_claims] || %{}

    typ = Map.get(claims, "typ", "access")

    if typ in @supported_typs do
      conn
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, ~s({"error":"unsupported_token_type"}))
      |> Plug.Conn.halt()
    end
  end
end
