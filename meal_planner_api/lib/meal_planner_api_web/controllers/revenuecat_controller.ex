defmodule MealPlannerApiWeb.RevenuecatController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Revenuecat

  def webhook(conn, payload) do
    headers =
      conn.req_headers
      |> Enum.into(%{}, fn {k, v} -> {String.downcase(k), v} end)

    case Revenuecat.process_webhook(payload, headers) do
      {:ok, data} -> json(conn, %{data: data})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def sync(conn, payload) do
    current_user = Guardian.Plug.current_resource(conn)

    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, data} <-
           Revenuecat.sync_entitlements_from_app(ids.account_id, ids.user_id, payload) do
      json(conn, %{data: data})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp render_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: serialize_reason(reason)})
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"
end
