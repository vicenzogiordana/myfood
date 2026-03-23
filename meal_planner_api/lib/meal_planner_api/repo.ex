defmodule MealPlannerApi.Repo do
  use Ecto.Repo,
    otp_app: :meal_planner_api,
    adapter: Ecto.Adapters.Postgres
end
