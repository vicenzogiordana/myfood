defmodule MealPlannerApi.Services.PlanningService do
  @moduledoc """
  Confirmed-plan use-cases outside the planning flow: reading, cooking and
  deleting scheduled meals, and slot favorites.

  Plans are produced only by the culinary agent
  (`MealPlannerApi.PlanningAgent.Session`); the legacy weekly-plan
  generation and its direct plan persistence were switched off in issue
  #110.
  """

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Identity

  # -------------------------------------------------------------------------
  # Scheduled meals
  # -------------------------------------------------------------------------

  @spec get_scheduled_meals(pos_integer(), Date.t(), Date.t()) :: [map()]
  def get_scheduled_meals(
        account_id,
        from_date \\ Date.utc_today(),
        to_date \\ Date.add(Date.utc_today(), 6)
      ) do
    meals = PlanningRepo.list_scheduled_meals(account_id, from_date, to_date)
    Enum.map(meals, &serialize_scheduled_meal/1)
  end

  @spec mark_meal_cooked(pos_integer()) :: {:ok, map()} | {:error, :not_found}
  def mark_meal_cooked(meal_id) do
    case PlanningRepo.get_scheduled_meal!(meal_id) do
      nil ->
        {:error, :not_found}

      meal ->
        {:ok, updated} = PlanningRepo.update_scheduled_meal(meal, %{is_cooked: true})
        {:ok, serialize_scheduled_meal(updated)}
    end
  end

  @spec delete_scheduled_meal(pos_integer()) :: :ok | {:error, term()}
  def delete_scheduled_meal(meal_id) do
    PlanningRepo.delete_scheduled_meal(meal_id)
    :ok
  rescue
    _ -> {:error, :not_found}
  end

  # -------------------------------------------------------------------------
  # Cooking sessions
  # -------------------------------------------------------------------------

  @spec start_cooking_session(pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, :meal_not_found}
  def start_cooking_session(account_id, user_id, scheduled_meal_id) do
    case MealPlannerApi.Services.CookingService.start_session(
           %{id: user_id, account_id: account_id},
           scheduled_meal_id
         ) do
      {:ok, session} ->
        {:ok,
         %{session_id: session.session_id, meal_id: scheduled_meal_id, recipe: session.recipe}}

      {:error, :scheduled_meal_not_found} ->
        {:error, :meal_not_found}

      error ->
        error
    end
  end

  @spec add_chat_message(pos_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def add_chat_message(_session_id, _content), do: {:error, :ephemeral_chat_only}

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp serialize_scheduled_meal(meal) do
    %{
      id: meal.id,
      date: meal.date,
      slot: Atom.to_string(meal.slot),
      recipe_id: meal.recipe_id,
      is_cooked: meal.is_cooked
    }
  end

  # -------------------------------------------------------------------------
  # Slot favorites
  # -------------------------------------------------------------------------

  @spec toggle_slot_favorite(map(), map()) :: {:ok, map()} | {:error, term()}
  def toggle_slot_favorite(user, payload) do
    with {:ok, identity} <- Identity.ensure_persistent_identity(user),
         {:ok, date} <- parse_date_service(Map.get(payload, "date")),
         slot_str when is_binary(slot_str) <- Map.get(payload, "slot"),
         {:ok, slot} <- parse_slot_service(slot_str),
         toggle_result <-
           PlanningRepo.toggle_slot_favorite(%{
             account_id: identity.account_id,
             user_id: identity.user_id,
             date: date,
             slot: slot
           }) do
      {:ok,
       case toggle_result do
         {:ok, %{status: :removed}} -> %{is_favorite: false}
         {:ok, %_{}} -> %{is_favorite: true}
         {:error, _} = error -> error
       end}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :invalid_slot}
      _ -> {:error, :invalid_payload}
    end
  end

  defp parse_date_service(nil), do: {:error, :missing_date}
  defp parse_date_service(%Date{} = d), do: {:ok, d}

  defp parse_date_service(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> {:ok, d}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_slot_service(s) when is_binary(s) do
    case s do
      "breakfast" -> {:ok, "breakfast"}
      "lunch" -> {:ok, "lunch"}
      "snack" -> {:ok, "snack"}
      "dinner" -> {:ok, "dinner"}
      _ -> nil
    end
  end
end
