defmodule MealPlannerApiWeb.PlanningController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Planning

  def weekly(conn, params) do
    user = Guardian.Plug.current_resource(conn)
    plan = Planning.weekly_plan_for(user, params)

    json(conn, %{data: Planning.serialize_plan(plan)})
  end
end
