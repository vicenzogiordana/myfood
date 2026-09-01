defmodule MealPlannerApiWeb.Plugs.SwitchAccountAuth do
  @moduledoc """
  Phase 4 — Conditional authentication for `POST /api/auth/switch-account`
  (`email-code-auth-account-selection`, task 4.2).

  ## Two modes

  The plug dispatches on the presence of `continuation_token` in the
  JSON request body:

    * **No continuation_token** — delegates to
      `MealPlannerApiWeb.AuthPipeline`. Behaviour is identical to the
      pre-Phase-4 `:auth` pipeline: Guardian-validated Bearer,
      `:current_user` (and `:current_membership`) populated.

    * **continuation_token present** — the opaque random token from
      `MealPlannerApi.Services.EmailCodeAuth.verify_code/3` is the
      credential. The plug:

        1. Hashes the plaintext (SHA-256 lower-case hex, mirroring
           `EmailCodeAuth.hash_continuation/1`).
        2. Loads the `AccountSelectionContinuation` row by
           `token_hash`. Missing → `401 invalid_continuation`.
        3. Rejects if `consumed_at` is set → `401 consumed_continuation`.
        4. Rejects if `expires_at < now` → `401 expired_continuation`.
        5. Optionally validates an `Authorization: Bearer …` header. If
           present, it must validate (`401 invalid_bearer` otherwise)
           AND its `sub` must equal the continuation's `user_id`
           (mismatch → `401 foreign_bearer`).
        6. On success, assigns `:current_user` from the continuation's
           `user_id` and `:current_membership` as `nil` (the controller
           resolves the new membership via
           `EmailCodeAuth.exchange_continuation/3`).

  The lock + consume + JWT mint happens inside
  `EmailCodeAuth.exchange_continuation/3`'s `Repo.transaction/1`, NOT in
  this plug — keeping this plug read-only preserves the design's
  "Minting and consumption commit together" guarantee.
  """

  @behaviour Plug

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Auth.AccountSelectionContinuation
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.EmailCodeAuth
  alias Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case extract_continuation_token(conn) do
      nil ->
        # No continuation → standard authenticated pipeline (legacy path).
        MealPlannerApiWeb.AuthPipeline.call(
          conn,
          MealPlannerApiWeb.AuthPipeline.init([])
        )

      plaintext when is_binary(plaintext) ->
        validate_continuation(conn, plaintext)
    end
  end

  # ---------------------------------------------------------------------------
  # Body parsing
  # ---------------------------------------------------------------------------

  defp extract_continuation_token(conn) do
    body = conn.body_params || %{}

    case Map.get(body, "continuation_token") do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Continuation validation
  # ---------------------------------------------------------------------------

  defp validate_continuation(conn, plaintext) do
    hash = EmailCodeAuth.hash_continuation(plaintext)

    case Repo.get_by(AccountSelectionContinuation, token_hash: hash) do
      nil ->
        halt_with(conn, 401, "invalid_continuation")

      %AccountSelectionContinuation{consumed_at: consumed} when not is_nil(consumed) ->
        halt_with(conn, 401, "consumed_continuation")

      %AccountSelectionContinuation{expires_at: expires_at} = row ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          halt_with(conn, 401, "expired_continuation")
        else
          assert_bearer_matches(conn, row)
        end
    end
  end

  # `nil` (bearerless) and `:invalid_bearer` (plug-detected malformed
  # token) are explicitly short-circuited — the former is the multi-
  # membership verify flow, the latter never reaches the controller.
  defp assert_bearer_matches(
         conn,
         %AccountSelectionContinuation{user_id: continuation_user_id}
       ) do
    case Conn.get_req_header(conn, "authorization") do
      [] ->
        # No bearer — the continuation token IS the credential.
        assign_resolved_user(conn, continuation_user_id)

      [header | _] ->
        case String.split(header, " ", parts: 2) do
          ["Bearer", token] when is_binary(token) and byte_size(token) > 0 ->
            decode_and_match(conn, token, continuation_user_id)

          _ ->
            halt_with(conn, 401, "invalid_bearer")
        end
    end
  end

  defp decode_and_match(conn, token, continuation_user_id) do
    case Guardian.decode_and_verify(token) do
      {:ok, %{"sub" => bearer_user_id}} when is_binary(bearer_user_id) ->
        if bearer_user_id == continuation_user_id do
          assign_resolved_user(conn, continuation_user_id)
        else
          halt_with(conn, 401, "foreign_bearer")
        end

      {:ok, _claims} ->
        halt_with(conn, 401, "invalid_bearer")

      {:error, _reason} ->
        halt_with(conn, 401, "invalid_bearer")
    end
  end

  defp assign_resolved_user(conn, user_id) do
    user = Repo.get!(PersistenceUser, user_id)

    conn
    |> Conn.assign(:current_user, user)
    |> Conn.assign(:current_membership, nil)
    |> Conn.assign(:switch_account_continuation, true)
  end

  # ---------------------------------------------------------------------------
  # Halt helper
  # ---------------------------------------------------------------------------

  defp halt_with(conn, status, error) do
    body = Jason.encode!(%{error: error})

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, body)
    |> Conn.halt()
  end
end
