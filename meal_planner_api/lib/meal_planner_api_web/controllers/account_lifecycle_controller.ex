defmodule MealPlannerApiWeb.AccountLifecycleController do
  @moduledoc """
  Multi-familia switch-account + self-leave flows (Phase A — Tenancy
  Refactor, PR 3a tasks 3.5 / 3.6). See
  `specs/multi-familia-switch-account.md` and
  `specs/invite-and-accept.md` §"Owner removes a member" (leave shares
  the owner-protection rule).
  """

  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  @doc """
  `POST /api/auth/switch-account` — body `{"membership_id": "<uuid>"}`.
  No `:account_id` in the URL — piped through `:auth` only (no
  `enforce_account_scope`, per design §5.2). Errors:
  `403 not_your_membership`, `409 membership_not_active`,
  `404 membership_not_found`.
  """
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
  defp error_status(_), do: :unprocessable_entity
end
