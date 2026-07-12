defmodule MealPlannerApiWeb.MembershipController do
  @moduledoc """
  Membership roster + owner-driven removal (Phase A — Tenancy Refactor,
  PR 3a tasks 3.1 / 3.2). See `specs/invite-and-accept.md`
  §"Membership roster" / §"Owner removes a member".
  """

  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  @doc """
  `GET /api/accounts/:account_id/memberships` — any `:active` (or
  `:invited`, per `AccountsMembership.list_memberships/1`) member of
  the Account may list the roster. Non-existent Accounts return `404
  account_not_found` (no existence leak) rather than a 403 — this is
  distinct from `EnforceAccountScope`'s blanket `403 account_mismatch`
  for URL/JWT tenancy mismatches (see `enforce_account_scope.ex`).
  """
  def index(conn, %{"account_id" => account_id}) do
    case AccountScopeHelpers.load_account(account_id) do
      {:ok, account} ->
        memberships = AccountsMembership.list_memberships(account)
        json(conn, %{memberships: Enum.map(memberships, &serialize/1)})

      {:error, :account_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "account_not_found"})
    end
  end

  @doc """
  `DELETE /api/accounts/:account_id/memberships/:user_id` — owner-only
  hard-delete. Errors: `403 not_owner`, `403 cannot_remove_owner`,
  `404 membership_not_found`.
  """
  def delete(conn, %{"account_id" => account_id, "user_id" => user_id}) do
    actor = conn.assigns.current_membership

    with {:ok, account} <- AccountScopeHelpers.load_account(account_id),
         {:ok, uuid} <- cast_target_user_id(user_id),
         :ok <- AccountsMembership.remove_member(account, uuid, actor) do
      send_resp(conn, :no_content, "")
    else
      {:error, :account_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "account_not_found"})

      {:error, reason} ->
        conn |> put_status(error_status(reason)) |> json(%{error: Atom.to_string(reason)})
    end
  end

  defp cast_target_user_id(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :membership_not_found}
    end
  end

  defp error_status(:not_owner), do: :forbidden
  defp error_status(:cannot_remove_owner), do: :forbidden
  defp error_status(:membership_not_found), do: :not_found
  defp error_status(_), do: :unprocessable_entity

  defp serialize(%{user: user} = membership) do
    %{
      user_id: to_string(membership.user_id),
      email: user.email,
      name: user.name,
      role: Atom.to_string(membership.role),
      status: Atom.to_string(membership.status),
      joined_at: membership.joined_at
    }
  end
end
