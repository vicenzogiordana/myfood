defmodule MealPlannerApiWeb.PlanningChatController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Services.PlanningChatService
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  # Phase A — Tenancy Refactor (PR 3c task 3.19): tenancy scope is always
  # resolved from `conn.assigns.current_membership.account_id`, never
  # from the legacy `current_user.account_id` field. See
  # `AccountScopeHelpers.scope_user_to_membership/2`.

  def favorites(conn, params) do
    user = scoped_user(conn)
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

  defp scoped_user(conn) do
    conn
    |> Guardian.Plug.current_resource()
    |> AccountScopeHelpers.scope_user_to_membership(conn.assigns.current_membership)
  end

  defp parse_limit(nil), do: 10

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 and n <= 50 -> n
      _ -> 10
    end
  end

  defp parse_limit(_), do: 10

  defp serialize_favorite(favorite) do
    %{
      recipe_id: favorite.recipe_id,
      name: favorite.recipe_name,
      slots: favorite.slots,
      prep_time_minutes: Map.get(favorite, :prep_time_minutes),
      calories_per_serving: Map.get(favorite, :calories_per_serving)
    }
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"
end
