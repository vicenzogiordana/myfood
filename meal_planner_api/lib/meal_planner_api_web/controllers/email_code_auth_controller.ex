defmodule MealPlannerApiWeb.EmailCodeAuthController do
  @moduledoc """
  HTTP entry point for email-code authentication.

  Phase 1 — Persistence and Code Request (issue #31).
  Phase 2 — Verification and Lockout (issue #31). Exposes
  `POST /api/auth/email-code/verify` (consumes the code, enforces
  principal binding and the rolling 1-hour failure lockout).
  Phase 4 — Verify response shape is the membership outcome
  (`task 4.2`). Three branches:

    * `:single`   → canonical auth payload (`access_token`,
      `refresh_token`, `user`, `account`, `membership`,
      `subscription`, `websocket`).
    * `:none`     → membership-less JWT + slim auth payload (no
      `account`, no `membership`). `LoadCurrentMembership` halts with
      `401 membership_id_required` on downstream use so the client
      routes to invite acceptance.
    * `:multiple` → summaries list + opaque `continuation_token`. No
      JWT — the client exchanges the continuation at
      `/api/auth/switch-account`.

  Both endpoints are thin translators that delegate the rate-limited,
  principal-bound work to
  `MealPlannerApi.Services.EmailCodeAuth`. The plaintext code is
  never returned, logged, or echoed by either endpoint — the
  configured mailer is the only delivery channel.
  """
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Accounts, as: AccountsContext
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.EmailCodeAuth
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  @doc """
  `POST /api/auth/email-code/request` — always returns
  `202 {"status": "sent"}` regardless of whether the email matches a
  User, and always sets `Retry-After` when the rolling 1-hour
  per-email or per-IP limit is exhausted.

  The plaintext code is never returned, logged, or echoed by this
  endpoint — the configured mailer is the only delivery channel.
  """
  def request(conn, %{"email" => email}) when is_binary(email) do
    client_ip = client_ip(conn)

    case EmailCodeAuth.request_code(email, client_ip) do
      {:ok, :sent} ->
        conn |> put_status(202) |> json(%{status: "sent"})

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(429)
        |> json(%{error: "rate_limited", retry_after: retry_after})
    end
  end

  @doc """
  `POST /api/auth/email-code/verify` — body `{email, code}` with
  optional Bearer.

  Outcomes (Phase 4 task 4.2):

    * `:single`   → `200 {access_token, refresh_token, user, account,
                          membership, subscription, websocket}` — the
                          canonical auth payload used by
                          `AuthController.password/2` and friends.
    * `:none`     → `200 {access_token, refresh_token, user}` — the
                          JWT intentionally OMITS `membership_id` so a
                          downstream `LoadCurrentMembership` halts with
                          `401 membership_id_required` and the client
                          routes to invite acceptance.
    * `:multiple` → `200 {memberships, continuation_token, expires_at}`
                          — the client exchanges the continuation at
                          `/api/auth/switch-account` to mint a JWT
                          scoped to a single selected membership.

  Error outcomes (Phase 2, unchanged):

    * `401 invalid_code` — wrong or expired code.
    * `401 code_already_used` — replay attempt.
    * `401 unauthorized_principal` — supplied bearer resolves to a
      different user than the code's owner.
    * `401 invalid_bearer` — plug detected an unparseable token.
    * `429 + Retry-After` — 10 prior failures in the last hour.

  The optional Bearer is decoded by
  `MealPlannerApiWeb.Plugs.OptionalBearerUser` upstream — this
  controller only reads `conn.assigns[:optional_current_user_id]`.
  """
  def verify(conn, %{"email" => email, "code" => code})
      when is_binary(email) and is_binary(code) do
    principal = Map.get(conn.assigns, :optional_current_user_id, nil)

    case EmailCodeAuth.verify_code(email, code, principal: principal) do
      {:ok, %{user_id: user_id, outcome: %{kind: :single} = outcome}} ->
        user = Repo.get!(PersistenceUser, user_id)
        render_single_outcome(conn, user, outcome)

      {:ok, %{user_id: user_id, outcome: %{kind: :none} = outcome}} ->
        user = Repo.get!(PersistenceUser, user_id)
        render_none_outcome(conn, user, outcome)

      {:ok, %{outcome: %{kind: :multiple} = outcome}} ->
        render_multiple_outcome(conn, outcome)

      {:ok, %{outcome: %{kind: kind}}} ->
        # Forward-compat guard: an unknown kind MUST surface as
        # `422 unprocessable_entity` so a service-side addition never
        # silently bypasses the controller.
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "unknown_outcome_kind", kind: Atom.to_string(kind)})

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(429)
        |> json(%{error: "rate_limited", retry_after: retry_after})

      {:error, reason}
      when reason in [:invalid_code, :code_already_used, :unauthorized_principal] ->
        conn
        |> put_status(401)
        |> json(%{error: Atom.to_string(reason)})
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 4 task 4.2 — outcome renderers
  # ---------------------------------------------------------------------------

  # `:single` reuses `AccountScopeHelpers.render_membership_auth_response/5`
  # (which mints a fresh access_token + refresh_token from the claims
  # already built by `EmailCodeAuth.build_outcome/1`). The
  # `Membership.account` association is preloaded by
  # `EmailCodeAuth.load_active_memberships/1`.
  defp render_single_outcome(conn, user, %{membership: membership, claims: claims}) do
    AccountScopeHelpers.render_membership_auth_response(
      conn,
      user,
      membership.account,
      membership,
      claims
    )
  end

  # `:none` mints a JWT without `membership_id` and returns the slim
  # auth payload. The `:active` membership count is zero, so
  # `AccountsMembership.claims_for/1` deliberately omits the field;
  # downstream `LoadCurrentMembership` halts with
  # `401 membership_id_required`.
  defp render_none_outcome(conn, user, %{claims: claims}) do
    case AccountScopeHelpers.mint_token_pair(user, claims) do
      {:ok, access_token, refresh_token} ->
        json(conn, %{
          access_token: access_token,
          refresh_token: refresh_token,
          token_type: "Bearer",
          user: AccountsContext.serialize_user(user),
          websocket: %{
            path: "/socket/websocket",
            params: %{token: access_token}
          }
        })

      _ ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "token_refresh_failed"})
    end
  end

  # `:multiple` does NOT mint a JWT — the client must exchange the
  # continuation at `/api/auth/switch-account` to mint a JWT scoped to
  # one of the returned summaries. `expires_at` is rendered as ISO8601
  # for client convenience.
  defp render_multiple_outcome(conn, %{
         summaries: summaries,
         continuation_token: token,
         expires_at: expires_at
       }) do
    json(conn, %{
      memberships: summaries,
      continuation_token: token,
      expires_at: DateTime.to_iso8601(expires_at)
    })
  end

  # Best-effort client IP extraction. We prefer the first
  # `X-Forwarded-For` entry (the original client when behind a proxy),
  # then fall back to `conn.remote_ip` rendered as a dotted IPv4. Any
  # unparsable shape collapses to `nil` so the per-email counter still
  # applies.
  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [ip | _] when is_binary(ip) and byte_size(ip) > 0 -> String.trim(ip)
      _ -> format_remote_ip(conn.remote_ip)
    end
  end

  defp format_remote_ip({a, b, c, d}) when is_integer(a) and is_integer(d) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_remote_ip(_), do: nil
end
