defmodule MealPlannerApiWeb.PlanningController do
  use MealPlannerApiWeb, :controller

  alias Ecto.Changeset
  alias MealPlannerApi.Planning

  def weekly(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case Planning.weekly_plan_for(user, params) do
      {:ok, plan} -> json(conn, %{data: Planning.serialize_plan(plan)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def confirm(conn, payload) do
    user = Guardian.Plug.current_resource(conn)

    case Planning.confirm_plan(user, payload) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp render_error(conn, %Changeset{}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "validation_error"})
  end

  defp render_error(conn, reason)
       when reason in [
              :invalid_payload,
              :invalid_meals,
              :duplicate_meal_slot,
              :exceeds_max_planning_days
            ] do
    conn
    |> put_status(:bad_request)
    |> json(%{error: Atom.to_string(reason)})
  end

  defp render_error(conn, reason) when is_atom(reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Atom.to_string(reason)})
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "unable_to_confirm_plan"})
  end
end
