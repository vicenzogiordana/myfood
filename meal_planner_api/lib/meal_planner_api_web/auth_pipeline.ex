defmodule MealPlannerApiWeb.AuthPipeline do
  @moduledoc """
  Plug pipeline that validates Bearer tokens and loads the current user.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :meal_planner_api,
    module: MealPlannerApi.Auth.Guardian,
    error_handler: MealPlannerApiWeb.AuthErrorHandler

  plug Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"}
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource, allow_blank: false
end
