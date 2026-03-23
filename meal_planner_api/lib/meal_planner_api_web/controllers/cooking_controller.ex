defmodule MealPlannerApiWeb.CookingController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.CookingAssistant

  def start(conn, %{"scheduled_meal_id" => scheduled_meal_id}) do
    user = Guardian.Plug.current_resource(conn)

    case CookingAssistant.start_session(user, scheduled_meal_id) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def show(conn, %{"session_id" => session_id}) do
    user = Guardian.Plug.current_resource(conn)

    case CookingAssistant.session_state(user, session_id) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def step(conn, %{"session_id" => session_id} = payload) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, recipe_step_id} <-
           require_binary(Map.get(payload, "recipe_step_id"), :invalid_recipe_step_id),
         {:ok, status} <- parse_step_status(Map.get(payload, "status")),
         {:ok, result} <-
           CookingAssistant.track_step(user, session_id, recipe_step_id, status, payload) do
      json(conn, %{data: result})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def finish(conn, %{"session_id" => session_id}) do
    user = Guardian.Plug.current_resource(conn)

    case CookingAssistant.finish_session(user, session_id) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp parse_step_status("started"), do: {:ok, :started}
  defp parse_step_status("paused"), do: {:ok, :paused}
  defp parse_step_status("completed"), do: {:ok, :completed}
  defp parse_step_status("error"), do: {:ok, :error}
  defp parse_step_status(_), do: {:error, :invalid_step_status}

  defp require_binary(value, _reason) when is_binary(value), do: {:ok, value}
  defp require_binary(_value, reason), do: {:error, reason}

  defp render_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: serialize_reason(reason)})
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"
end
