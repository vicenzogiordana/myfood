defmodule MealPlannerApiWeb.PlanningChatController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Services.PlanningChatService

  def create(conn, payload) do
    user = Guardian.Plug.current_resource(conn)

    case PlanningChatService.generate_menu(user, payload) do
      {:ok, result} ->
        json(conn, %{data: serialize_generation(result)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: serialize_reason(reason)})
    end
  end

  def favorites(conn, params) do
    user = Guardian.Plug.current_resource(conn)
    limit = parse_limit(Map.get(params, "limit"))

    case PlanningChatService.quick_favorites(user, limit) do
      {:ok, favorites} ->
        json(conn, %{data: Enum.map(favorites, &serialize_favorite/1)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: serialize_reason(reason)})
    end
  end

  def confirm(conn, %{"proposal_id" => proposal_id}) do
    user = Guardian.Plug.current_resource(conn)

    case PlanningChatService.confirm_proposal(user, proposal_id) do
      {:ok, result} ->
        json(conn, %{data: serialize_confirmation(result)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: serialize_reason(reason)})
    end
  end

  def reject(conn, %{"proposal_id" => proposal_id}) do
    user = Guardian.Plug.current_resource(conn)

    case PlanningChatService.reject_proposal(user, proposal_id) do
      {:ok, result} ->
        json(conn, %{data: serialize_rejection(result)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: serialize_reason(reason)})
    end
  end

  defp parse_limit(nil), do: 10

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 and n <= 50 -> n
      _ -> 10
    end
  end

  defp parse_limit(_), do: 10

  defp serialize_generation(result) do
    %{
      run_id: result.run.id,
      proposal_id: result.proposal.id,
      date_from: Date.to_iso8601(result.date_from),
      date_to: Date.to_iso8601(result.date_to),
      proposal: result.proposal_json
    }
  end

  defp serialize_favorite(favorite) do
    %{
      recipe_id: favorite.recipe_id,
      name: favorite.recipe_name,
      slots: favorite.slots,
      prep_time_minutes: Map.get(favorite, :prep_time_minutes),
      calories_per_serving: Map.get(favorite, :calories_per_serving)
    }
  end

  defp serialize_confirmation(result) do
    %{
      proposal_id: result.proposal_id,
      generation_run_id: result.generation_run_id,
      scheduled_meals_count: result.scheduled_meals_count,
      status: "confirmed"
    }
  end

  defp serialize_rejection(result) do
    %{
      proposal_id: result.proposal_id,
      generation_run_id: result.generation_run_id,
      status: "rejected"
    }
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"
end
