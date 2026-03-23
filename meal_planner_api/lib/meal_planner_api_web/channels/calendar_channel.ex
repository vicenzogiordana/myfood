defmodule MealPlannerApiWeb.CalendarChannel do
  use MealPlannerApiWeb, :channel

  alias MealPlannerApi.Persistence.Calendar

  @impl true
  def join("calendar:" <> account_id, _payload, socket) do
    user = socket.assigns.current_user

    if user.account_id == account_id do
      {:ok, assign(socket, :account_id, account_id)}
    else
      {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in("toggle_favorite", %{"recipe_id" => recipe_id}, socket)
      when is_binary(recipe_id) do
    user = socket.assigns.current_user

    case Calendar.toggle_favorite(user.account_id, user.id, recipe_id) do
      {:ok, is_favorite} ->
        payload = %{user_id: user.id, recipe_id: recipe_id, is_favorite: is_favorite}
        broadcast!(socket, "favorite_toggled", payload)
        {:reply, {:ok, payload}, socket}

      {:error, _} ->
        {:reply, {:error, %{reason: "favorite_toggle_failed"}}, socket}
    end
  end

  def handle_in("upsert_meal", payload, socket) do
    user = socket.assigns.current_user

    with {:ok, date} <- parse_date(Map.get(payload, "date")),
         {:ok, slot} <- parse_slot(Map.get(payload, "slot")),
         attrs <- upsert_attrs(payload, date, slot),
         {:ok, meal} <- Calendar.upsert_scheduled_meal(user.account_id, attrs) do
      event = %{
        meal_id: meal.id,
        account_id: meal.account_id,
        date: Date.to_iso8601(meal.date),
        slot: Atom.to_string(meal.slot),
        recipe_id: meal.recipe_id,
        is_cooked: meal.is_cooked
      }

      broadcast!(socket, "meal_updated", event)
      {:reply, {:ok, event}, socket}
    else
      {:error, reason} when is_binary(reason) -> {:reply, {:error, %{reason: reason}}, socket}
      {:error, _} -> {:reply, {:error, %{reason: "upsert_failed"}}, socket}
    end
  end

  def handle_in("delete_meal", payload, socket) do
    user = socket.assigns.current_user

    with {:ok, date} <- parse_date(Map.get(payload, "date")),
         {:ok, slot} <- parse_slot(Map.get(payload, "slot")),
         {:ok, _meal} <- Calendar.delete_scheduled_meal(user.account_id, date, slot) do
      event = %{date: Date.to_iso8601(date), slot: Atom.to_string(slot)}
      broadcast!(socket, "meal_deleted", event)
      {:reply, {:ok, event}, socket}
    else
      {:error, reason} when is_binary(reason) -> {:reply, {:error, %{reason: reason}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{reason: "not_found"}}, socket}
      {:error, _} -> {:reply, {:error, %{reason: "delete_failed"}}, socket}
    end
  end

  def handle_in("set_is_cooked", payload, socket) do
    user = socket.assigns.current_user

    meal_id = Map.get(payload, "meal_id")
    is_cooked = Map.get(payload, "is_cooked")

    cond do
      not is_binary(meal_id) ->
        {:reply, {:error, %{reason: "missing_params"}}, socket}

      not is_boolean(is_cooked) ->
        {:reply, {:error, %{reason: "invalid_is_cooked"}}, socket}

      true ->
        case Calendar.set_is_cooked(user.account_id, meal_id, is_cooked) do
          {:ok, meal} ->
            event = %{meal_id: meal.id, is_cooked: meal.is_cooked}
            broadcast!(socket, "meal_cooked_state_changed", event)
            {:reply, {:ok, event}, socket}

          {:error, :not_found} ->
            {:reply, {:error, %{reason: "not_found"}}, socket}

          {:error, _} ->
            {:reply, {:error, %{reason: "set_is_cooked_failed"}}, socket}
        end
    end
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  defp upsert_attrs(payload, date, slot) do
    %{
      date: date,
      slot: slot,
      recipe_id: Map.get(payload, "recipe_id"),
      is_cooked: Map.get(payload, "is_cooked", false)
    }
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_date_format"}
    end
  end

  defp parse_date(_), do: {:error, "invalid_date_format"}

  defp parse_slot("breakfast"), do: {:ok, :breakfast}
  defp parse_slot("lunch"), do: {:ok, :lunch}
  defp parse_slot("snack"), do: {:ok, :snack}
  defp parse_slot("dinner"), do: {:ok, :dinner}
  defp parse_slot(_), do: {:error, "invalid_slot"}
end
