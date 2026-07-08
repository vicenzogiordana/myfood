defmodule MealPlannerApiWeb.InviteController do
  @moduledoc """
  Owner-invites-member + invitee-accepts flows (Phase A — Tenancy
  Refactor, PR 3a tasks 3.3 / 3.4). See `specs/invite-and-accept.md`.
  """

  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  @doc """
  `POST /api/accounts/:account_id/invites` — owner-only. Body:
  `{"email": "..."}`. Returns `201 {invite: {token, expires_at,
  membership_id, email}}`. Errors per spec §6.1: `403 not_owner`,
  `409 seat_cap_reached`, `409 already_invited`, `409 already_a_member`.
  """
  def create(conn, %{"account_id" => account_id, "email" => email}) do
    actor = conn.assigns.current_membership

    with {:ok, account} <- AccountScopeHelpers.load_account(account_id),
         {:ok, result} <- AccountsMembership.invite(account, actor, email) do
      conn
      |> put_status(:created)
      |> json(%{
        invite: %{
          token: result.token,
          expires_at: result.expires_at,
          membership_id: result.membership_id,
          email: result.email
        }
      })
    else
      {:error, :account_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "account_not_found"})

      {:error, reason} ->
        conn |> put_status(error_status(reason)) |> json(%{error: Atom.to_string(reason)})
    end
  end

  defp error_status(:not_owner), do: :forbidden
  defp error_status(:seat_cap_reached), do: :conflict
  defp error_status(:already_invited), do: :conflict
  defp error_status(:already_a_member), do: :conflict
  defp error_status(_), do: :unprocessable_entity
end
