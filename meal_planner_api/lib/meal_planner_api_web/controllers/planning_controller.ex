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

  def weekly(conn, params) do
    user = scoped_user(conn)

    case PlanningService.generate_weekly_plan(user, params) do
      {:ok, plan} ->
        json(conn, %{data: plan})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def confirm(conn, payload) do
    user = Guardian.Plug.current_resource(conn)
    membership = conn.assigns.current_membership
    meals = Map.get(payload, "meals", [])

    if is_list(meals) do
      case PlanningService.save_plan(membership.account_id, user.id, meals) do
        {:ok, %{proposal_id: _proposal_id, meal_ids: meal_ids}} ->
          json(conn, %{data: %{scheduled_meals_count: length(meal_ids)}})

        {:error, reason} ->
          render_error(conn, reason)
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "invalid_payload"})
    end
  end

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
  defp error_status(:optimization_failed), do: :unprocessable_entity
  defp error_status(_), do: :unprocessable_entity

  defp render_error(conn, reason) when is_atom(reason) do
    conn
    |> put_status(status_for(reason))
    |> json(%{error: Atom.to_string(reason)})
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "optimization_failed"})
  end

  defp status_for(:identity_resolution_failed), do: :unauthorized
  defp status_for(:optimization_failed), do: :unprocessable_entity
  defp status_for(:persistence_failed), do: :unprocessable_entity
  defp status_for(:exceeds_max_planning_days), do: :bad_request
  defp status_for(_), do: :unprocessable_entity
end
