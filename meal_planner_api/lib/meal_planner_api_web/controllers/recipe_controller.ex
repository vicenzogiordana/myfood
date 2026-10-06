defmodule MealPlannerApiWeb.RecipeController do
  use MealPlannerApiWeb, :controller
  alias MealPlannerApi.Services.RecipeService
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  def show(conn, %{"id" => id}) do
    user =
      Guardian.Plug.current_resource(conn)
      |> AccountScopeHelpers.scope_user_to_membership(conn.assigns.current_membership)

    case RecipeService.get_recipe(user, id) do
      {:ok, recipe} ->
        json(conn, %{data: recipe})

      {:error, :subscription_required} ->
        conn |> put_status(:forbidden) |> json(%{error: :subscription_required})

      {:error, _} ->
        conn |> put_status(:not_found) |> json(%{error: :not_found})
    end
  end
end
