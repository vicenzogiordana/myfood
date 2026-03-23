defmodule MealPlannerApiWeb.InventoryController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.InventoryHub

  def index(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    case InventoryHub.inventory_view(user) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def add_extra(conn, payload) do
    user = Guardian.Plug.current_resource(conn)

    case InventoryHub.add_extra_item(user, payload) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def update_quantity(conn, %{"item_id" => item_id} = payload) do
    user = Guardian.Plug.current_resource(conn)

    case InventoryHub.adjust_item_quantity(user, item_id, payload) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def dispose(conn, %{"item_id" => item_id} = payload) do
    user = Guardian.Plug.current_resource(conn)

    case InventoryHub.dispose_item(user, item_id, payload) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def voice_preview(conn, payload) do
    user = Guardian.Plug.current_resource(conn)

    case InventoryHub.voice_preview(user, payload) do
      {:ok, data} -> json(conn, %{data: data})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def voice_apply(conn, payload) do
    user = Guardian.Plug.current_resource(conn)

    case InventoryHub.voice_apply(user, payload) do
      {:ok, data} -> json(conn, %{data: data})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def rescue_plan(conn, payload) do
    user = Guardian.Plug.current_resource(conn)

    case InventoryHub.rescue_plan(user, payload) do
      {:ok, data} -> json(conn, %{data: data})
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
