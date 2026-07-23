defmodule MealPlannerApiWeb.ShoppingController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Services.ShoppingService
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  # Phase A — Tenancy Refactor (PR 3c task 3.17): tenancy scope is always
  # resolved from `conn.assigns.current_membership.account_id`, never
  # from the legacy `current_user.account_id` field. See
  # `AccountScopeHelpers.scope_user_to_membership/2`.

  def index(conn, params) do
    user = scoped_user(conn)

    case ShoppingService.get_shopping_list(user, params) do
      {:ok, payload} -> json(conn, %{data: payload})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def mark_cart(conn, payload) do
    user = scoped_user(conn)

    # Support both item_ids (list of item IDs) and ingredient_id (mark all items for ingredient)
    item_ids = Map.get(payload, "item_ids")
    ingredient_id = Map.get(payload, "ingredient_id")

    cond do
      is_list(item_ids) and length(item_ids) > 0 ->
        # Mark specific items by item_ids
        case ShoppingService.mark_in_cart(user, item_ids) do
          {:ok, response} -> json(conn, %{data: response})
          {:error, reason} -> render_error(conn, reason)
        end

      is_binary(ingredient_id) ->
        # Mark all items for this ingredient in date range as in_cart
        from_date = parse_date_param(payload["start_date"])
        end_date = parse_date_param(payload["end_date"])

        case ShoppingService.mark_ingredient_in_cart(user, ingredient_id, from_date, end_date) do
          {:ok, response} -> json(conn, %{data: response})
          {:error, reason} -> render_error(conn, reason)
        end

      true ->
        render_error(conn, :invalid_payload)
    end
  end

  def assign_supermarket(conn, payload) do
    user = scoped_user(conn)

    # Support both item_id (single item) and ingredient_id (assign all for ingredient in range)
    item_id = Map.get(payload, "item_id")
    ingredient_id = Map.get(payload, "ingredient_id")
    supermarket_id = Map.get(payload, "supermarket_id")

    cond do
      is_binary(item_id) ->
        case ShoppingService.assign_supermarket(user, item_id, supermarket_id) do
          {:ok, response} -> json(conn, %{data: response})
          {:error, reason} -> render_error(conn, reason)
        end

      is_binary(ingredient_id) ->
        from_date = parse_date_param(payload["start_date"])
        end_date = parse_date_param(payload["end_date"])

        case ShoppingService.assign_ingredient_supermarket(
               user,
               ingredient_id,
               supermarket_id,
               from_date,
               end_date
             ) do
          {:ok, response} -> json(conn, %{data: response})
          {:error, reason} -> render_error(conn, reason)
        end

      true ->
        render_error(conn, :invalid_payload)
    end
  end

  def confirm_checkout(conn, payload) do
    user = scoped_user(conn)

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
      {:error, _} -> Date.utc_today()
    end
  end

  defp parse_date_param(d), do: d

  def confirm_delivery(conn, %{"checkout_session_id" => checkout_session_id}) do
    user = scoped_user(conn)

    case ShoppingService.confirm_delivery(user, checkout_session_id) do
      {:ok, response} -> json(conn, %{data: response})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp scoped_user(conn) do
    conn
    |> Guardian.Plug.current_resource()
    |> AccountScopeHelpers.scope_user_to_membership(conn.assigns.current_membership)
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
