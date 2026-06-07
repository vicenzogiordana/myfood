defmodule MealPlannerApiWeb.CalendarController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Persistence.Calendar

  def index(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, start_date} <- parse_date(Map.get(params, "start_date")),
         {:ok, end_date} <- parse_date(Map.get(params, "end_date")),
         :ok <- validate_date_range(start_date, end_date),
         {:ok, selected_date} <-
           parse_optional_date(Map.get(params, "selected_date"), Date.utc_today()),
         {:ok, selected_slot} <- parse_optional_slot(Map.get(params, "selected_slot"), :lunch) do
      data =
        Calendar.monthly_overview(user.account_id, user.id, start_date, end_date, %{
          selected_date: selected_date,
          selected_slot: selected_slot
        })

      json(conn, %{data: serialize_payload(data)})
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  def show_slot(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, date} <- parse_date(Map.get(params, "date")),
         {:ok, slot} <- parse_slot(Map.get(params, "slot")),
         {:ok, meal} <- get_slot_meal_result(user, date, slot) do
      json(conn, %{data: serialize_slot_response(meal, date, slot)})
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  defp get_slot_meal_result(user, date, slot) do
    case Calendar.get_slot_meal(user.account_id, user.id, date, slot) do
      nil -> {:ok, nil}
      meal -> {:ok, meal}
    end
  end

  defp validate_date_range(start_date, end_date) do
    if Date.compare(start_date, end_date) in [:lt, :eq] do
      :ok
    else
      {:error, "invalid_date_range"}
    end
  end

  defp parse_optional_date(nil, default), do: {:ok, default}
  defp parse_optional_date(value, _default), do: parse_date(value)

  defp parse_optional_slot(nil, default), do: {:ok, default}

  defp parse_optional_slot(value, _default) when is_binary(value) do
    case value do
      "breakfast" -> {:ok, :breakfast}
      "lunch" -> {:ok, :lunch}
      "snack" -> {:ok, :snack}
      "dinner" -> {:ok, :dinner}
      _ -> {:error, "invalid_slot"}
    end
  end

  defp parse_optional_slot(_, _default), do: {:error, "invalid_slot"}

  defp parse_date(nil), do: {:error, "missing_date_param"}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_date_format"}
    end
  end

  defp parse_date(_), do: {:error, "invalid_date_format"}

  # Required slot parser (used by show_slot)
  defp parse_slot(nil), do: {:error, "missing_slot_param"}

  defp parse_slot(value) when is_binary(value) do
    case value do
      "breakfast" -> {:ok, :breakfast}
      "lunch" -> {:ok, :lunch}
      "snack" -> {:ok, :snack}
      "dinner" -> {:ok, :dinner}
      _ -> {:error, "invalid_slot"}
    end
  end

  defp parse_slot(_), do: {:error, "invalid_slot"}

  defp serialize_payload(payload) do
    %{
      start_date: Date.to_iso8601(payload.start_date),
      end_date: Date.to_iso8601(payload.end_date),
      today: Date.to_iso8601(payload.today),
      selected_date: Date.to_iso8601(payload.selected_date),
      selected_slot: Atom.to_string(payload.selected_slot),
      days: Enum.map(payload.days, &serialize_day/1),
      meals: Enum.map(payload.meals, &serialize_meal/1),
      selected_meal: serialize_selected_meal(payload.selected_meal)
    }
  end

  defp serialize_day(day) do
    %{
      date: Date.to_iso8601(day.date),
      day_state: Atom.to_string(day.day_state),
      has_planned_menu: day.has_planned_menu,
      is_selected: day.is_selected
    }
  end

  defp serialize_meal(meal) do
    %{
      meal_id: meal.id,
      date: Date.to_iso8601(meal.date),
      slot: Atom.to_string(meal.slot),
      is_cooked: meal.is_cooked,
      recipe_id: meal.recipe_id,
      recipe_name: meal.recipe_name,
      is_favorite: meal.is_favorite,
      can_create: false,
      macros: %{calories: meal.calories_per_serving},
      prep_time_minutes: meal.prep_time_minutes
    }
  end

  defp serialize_selected_meal(nil), do: nil

  defp serialize_selected_meal(meal) do
    base = serialize_meal(meal)
    Map.put(base, :can_create, is_nil(meal.recipe_id))
  end

  # Serializers for slot response (show_slot endpoint)

  defp serialize_slot_response(nil, date, slot) do
    # Empty slot — can create
    %{
      meal_id: nil,
      date: Date.to_iso8601(date),
      slot: Atom.to_string(slot),
      recipe_id: nil,
      recipe_name: nil,
      is_cooked: false,
      is_favorite: false,
      can_create: true,
      macros: nil,
      prep_time_minutes: nil
    }
  end

  defp serialize_slot_response(meal, _date, _slot) do
    # Filled slot — can_create is always false for existing meals
    serialize_meal(meal)
    |> Map.put(:can_create, false)
  end
end
