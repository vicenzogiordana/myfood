defmodule MealPlannerApiWeb.ShoppingController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.ShoppingCheckout

  def index(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case ShoppingCheckout.list_shopping_view(user, params) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def mark_cart(conn, %{"ingredient_id" => ingredient_id} = payload) do
    user = Guardian.Plug.current_resource(conn)
    in_cart = parse_bool(Map.get(payload, "in_cart", true))

    case ShoppingCheckout.mark_cart(user, ingredient_id, in_cart, payload) do
      {:ok, response} -> json(conn, %{data: response})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def assign_supermarket(
        conn,
        %{"ingredient_id" => ingredient_id, "supermarket_id" => supermarket_id} = payload
      ) do
    user = Guardian.Plug.current_resource(conn)

    case ShoppingCheckout.assign_supermarket(user, ingredient_id, supermarket_id, payload) do
      {:ok, response} -> json(conn, %{data: response})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def confirm_checkout(conn, payload) do
    user = Guardian.Plug.current_resource(conn)

    case ShoppingCheckout.confirm_checkout(user, payload) do
      {:ok, response} -> json(conn, %{data: response})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def confirm_delivery(conn, %{"checkout_session_id" => checkout_session_id}) do
    user = Guardian.Plug.current_resource(conn)

    case ShoppingCheckout.confirm_delivery_arrived(user, checkout_session_id) do
      {:ok, response} -> json(conn, %{data: response})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp parse_bool(true), do: true
  defp parse_bool("true"), do: true
  defp parse_bool(_), do: false

  defp render_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: serialize_reason(reason)})
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"
end
