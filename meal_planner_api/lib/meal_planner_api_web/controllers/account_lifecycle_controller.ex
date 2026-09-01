defmodule MealPlannerApiWeb.AccountLifecycleController do
  @moduledoc """
  Multi-familia switch-account + self-leave flows (Phase A — Tenancy
  Refactor, PR 3a tasks 3.5 / 3.6 + Phase 4 task 4.2 conditional
  authentication). See `specs/multi-familia-switch-account.md`,
  `specs/invite-and-accept.md` §"Owner removes a member" (leave shares
  the owner-protection rule), and `specs/email-code-authentication/spec.md`
  §"Selection Continuation Security".
  """

  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Services.EmailCodeAuth
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  @doc """
  `POST /api/auth/switch-account` — two branches dispatched on the
  presence of `continuation_token` in the body.

  ## Continuation branch (Phase 4 task 4.2)

  Body `%{"membership_id" => <uuid>, "continuation_token" => <plain>}`.

  The `Plugs.SwitchAccountAuth` pipeline has already validated the
  continuation's hash, freshness, and (if present) bearer match —
  the controller only needs to:

    1. Delegate to `EmailCodeAuth.exchange_continuation/3`, which
       re-locks the row, runs the membership-set + bearer checks
       again (defense in depth), delegates to
       `AccountsMembership.switch_account/2`, mints the `access_v2`
       JWT inside the same `Repo.transaction/1`, and consumes the
       continuation row.
    2. Render the canonical auth payload (the same shape as the
       legacy branch) using `AccountScopeHelpers.render_exchange_response/2`.

  Errors: `401 invalid_continuation`, `401 consumed_continuation`,
  `401 expired_continuation`, `401 foreign_bearer`,
  `403 not_in_continuation_set`, `409 membership_not_active`,
  `404 membership_not_found`, `403 not_your_membership`,
  `500 token_refresh_failed`.

  ## Legacy branch

  Body `%{"membership_id" => <uuid>}` (no `continuation_token`). The
  `Plugs.SwitchAccountAuth` pipeline has populated
  `Guardian.Plug.current_resource/1` from the Authorization header,
  so this branch is the same as the pre-Phase-4 controller.

  Errors: `403 not_your_membership`, `409 membership_not_active`,
  `404 membership_not_found`.
  """
  def switch_account(
        conn,
        %{"membership_id" => membership_id, "continuation_token" => plaintext}
      ) do
    principal = resolve_principal(conn)

    case EmailCodeAuth.exchange_continuation(plaintext, membership_id, principal: principal) do
      {:ok, payload} ->
        AccountScopeHelpers.render_exchange_response(conn, payload)

      {:error, reason} ->
        conn |> put_status(error_status(reason)) |> json(%{error: Atom.to_string(reason)})
    end
  end

  def switch_account(conn, %{"membership_id" => membership_id}) do
    user = Guardian.Plug.current_resource(conn)

    case AccountsMembership.switch_account(user, membership_id) do
      {:ok, %{user: u, account: account, membership: membership, claims: claims}} ->
        AccountScopeHelpers.render_membership_auth_response(
          conn,
          u,
          account,
          membership,
          claims
        )

      {:error, reason} ->
        conn |> put_status(error_status(reason)) |> json(%{error: Atom.to_string(reason)})
    end
  end

  @doc """
  `POST /api/accounts/:account_id/leave` — self-removal for a
  `:member`. Owners cannot leave: `403 cannot_leave_owned_account`.
  Non-members: `404 not_a_member`.
  """
  def leave(conn, %{"account_id" => account_id}) do
    actor = conn.assigns.current_membership

    with {:ok, account} <- AccountScopeHelpers.load_account(account_id),
         :ok <- AccountsMembership.leave(account, actor) do
      send_resp(conn, :no_content, "")
    else
      {:error, :account_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "account_not_found"})

      {:error, reason} ->
        conn |> put_status(error_status(reason)) |> json(%{error: Atom.to_string(reason)})
    end
  end

  defp error_status(:not_your_membership), do: :forbidden
  defp error_status(:membership_not_active), do: :conflict
  defp error_status(:membership_not_found), do: :not_found
  defp error_status(:cannot_leave_owned_account), do: :forbidden
  defp error_status(:not_a_member), do: :not_found
  defp error_status(:not_in_continuation_set), do: :forbidden
  defp error_status(:token_refresh_failed), do: :internal_server_error
  defp error_status(_), do: :unprocessable_entity

  # Continuation exchange's principal binding: prefer the User resolved
  # by the `Plugs.SwitchAccountAuth` pipeline (it carries the
  # continuation's `user_id`); fall back to the Guardian-loaded
  # resource for the bearer-authenticated case. The service's
  # `assert_continuation_bearer/2` double-checks either way.
  defp resolve_principal(conn) do
    case conn.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end
end
