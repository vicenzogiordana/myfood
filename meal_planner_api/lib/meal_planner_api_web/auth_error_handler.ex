defmodule MealPlannerApiWeb.AuthErrorHandler do
  @moduledoc false

  use MealPlannerApiWeb, :controller

  @behaviour Guardian.Plug.ErrorHandler

  @impl true
  def auth_error(conn, {type, _reason}, _opts) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized", reason: to_string(type)})
  end
end
