defmodule MealPlannerApiWeb.ShoppingController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Services.ShoppingService

  def index(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case ShoppingService.get_shopping_list(user, params) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def mark_cart(conn, %{"item_ids" => item_ids} = payload) do
    user = Guardian.Plug.current_resource(conn)
    in_cart = parse_bool(Map.get(payload, "in_cart", true))

    if in_cart do
      case ShoppingService.mark_in_cart(user, item_ids) do
        {:ok, response} -> json(conn, %{data: response})
        {:error, reason} -> render_error(conn, reason)
      end
    else
      render_error(conn, :not_implemented)
    end
  end

  def assign_supermarket(conn, %{"item_id" => item_id, "supermarket_id" => supermarket_id}) do
    user = Guardian.Plug.current_resource(conn)

    case ShoppingService.assign_supermarket(user, item_id, supermarket_id) do
      {:ok, response} -> json(conn, %{data: response})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def confirm_checkout(conn, payload) do
    user = Guardian.Plug.current_resource(conn)

    # Support both session_id (path param) and date-range checkout (body params)
    session_id = Map.get(payload, "session_id")
    checkout_type = Map.get(payload, "checkout_type")

    cond do
      session_id ->
        case ShoppingService.confirm_checkout(user, session_id, payload) do
          {:ok, response} -> json(conn, %{data: response})
          {:error, reason} -> render_error(conn, reason)
        end

      checkout_type ->
        # Date-range based checkout: create session from items in range
        start_date = parse_date_param(payload["start_date"])
        end_date = parse_date_param(payload["end_date"])

        case ShoppingService.create_checkout_from_range(user, start_date, end_date, checkout_type) do
          {:ok, response} -> json(conn, %{data: response})
          {:error, reason} -> render_error(conn, reason)
        end

      true ->
        render_error(conn, :invalid_payload)
    end
  end

  defp parse_date_param(nil), do: Date.utc_today()
  defp parse_date_param(d) when is_binary(d) do
    case Date.from_iso8601(d) do
      {:ok, date} -> date
      :error -> Date.utc_today()
    end
  end
  defp parse_date_param(d), do: d

  def confirm_delivery(conn, %{"checkout_session_id" => checkout_session_id}) do
    user = Guardian.Plug.current_resource(conn)

    case ShoppingService.confirm_delivery(user, checkout_session_id) do
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
