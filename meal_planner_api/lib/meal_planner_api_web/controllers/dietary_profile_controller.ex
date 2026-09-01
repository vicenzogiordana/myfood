defmodule MealPlannerApiWeb.DietaryProfileController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Services.AccountService
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  def show(conn, _params) do
    with {:ok, profile} <- AccountService.dietary_profile(scoped_user(conn)) do
      json(conn, %{data: profile})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def update(conn, attrs) do
    with {:ok, profile} <- AccountService.update_dietary_profile(scoped_user(conn), attrs) do
      json(conn, %{data: profile})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def index_exclusions(conn, _params) do
    with {:ok, exclusions} <- AccountService.list_excluded_ingredients(scoped_user(conn)) do
      json(conn, %{data: exclusions})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def create_exclusion(conn, %{"ingredient_id" => ingredient_id, "reason" => reason}) do
    with {:ok, exclusion} <-
           AccountService.add_excluded_ingredient(scoped_user(conn), ingredient_id, reason) do
      conn
      |> put_status(:created)
      |> json(%{data: exclusion})
    else
      {:error, error} -> render_error(conn, error)
    end
  end

  def create_exclusion(conn, _params), do: render_error(conn, :invalid_exclusion)

  def delete_exclusion(conn, %{"ingredient_id" => ingredient_id}) do
    case AccountService.remove_excluded_ingredient(scoped_user(conn), ingredient_id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp scoped_user(conn) do
    conn
    |> Guardian.Plug.current_resource()
    |> AccountScopeHelpers.scope_user_to_membership(conn.assigns.current_membership)
  end

  defp render_error(conn, :identity_resolution_failed) do
    conn |> put_status(:unauthorized) |> json(%{error: "identity_resolution_failed"})
  end

  defp render_error(conn, :invalid_exclusion) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_exclusion"})
  end

  defp render_error(conn, _reason) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_dietary_profile"})
  end
end
