defmodule MealPlannerApiWeb.Router do
  use MealPlannerApiWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :auth do
    plug MealPlannerApiWeb.AuthPipeline
  end

  scope "/api", MealPlannerApiWeb do
    pipe_through :api

    post "/auth/token", AuthController, :create
  end

  scope "/api", MealPlannerApiWeb do
    pipe_through [:api, :auth]

    get "/me", AccountsController, :me
    get "/account/context", AccountsController, :context
    get "/planning/weekly", PlanningController, :weekly
  end
end
