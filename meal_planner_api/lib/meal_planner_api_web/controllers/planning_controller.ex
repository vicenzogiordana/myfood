defmodule MealPlannerApiWeb.PlanningController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Services.PlanningService
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  # Phase A — Tenancy Refactor (PR 3c task 3.15): tenancy scope is always
  # resolved from `conn.assigns.current_membership.account_id`, never
  # from the legacy `current_user.account_id` field. See
  # `AccountScopeHelpers.scope_user_to_membership/2` for why the User
  # struct is corrected at the controller boundary rather than rewriting
  # every downstream service signature.

  def toggle_slot_favorite(conn, payload) do
    user = scoped_user(conn)

    case PlanningService.toggle_slot_favorite(user, payload) do
      {:ok, result} ->
        json(conn, result)

      {:error, reason} ->
        conn
        |> put_status(error_status(reason))
        |> json(%{error: Atom.to_string(reason)})
    end
  end

  defp scoped_user(conn) do
    conn
    |> Guardian.Plug.current_resource()
    |> AccountScopeHelpers.scope_user_to_membership(conn.assigns.current_membership)
  end

  defp error_status(:invalid_date), do: :bad_request
  defp error_status(:invalid_slot), do: :bad_request
  defp error_status(:identity_resolution_failed), do: :unauthorized
  defp error_status(_), do: :unprocessable_entity
end
