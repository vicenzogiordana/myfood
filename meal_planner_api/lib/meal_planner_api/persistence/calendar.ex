defmodule MealPlannerApi.Persistence.Calendar do
  @moduledoc "Calendar-oriented read/write operations for Home view with realtime collaboration."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Catalog.{FavoriteRecipe, SlotFavorite}
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal

  @default_slot :lunch

  def monthly_overview(account_id, user_id, start_date, end_date, opts \\ %{}) do
    selected_date = Map.get(opts, :selected_date, Date.utc_today())
    selected_slot = Map.get(opts, :selected_slot, @default_slot)
    today = Date.utc_today()

    meals =
      from(m in ScheduledMeal,
        where: m.account_id == ^account_id and m.date >= ^start_date and m.date <= ^end_date,
        left_join: r in assoc(m, :recipe),
        left_join: f in FavoriteRecipe,
        on: f.account_id == m.account_id and f.user_id == ^user_id and f.recipe_id == m.recipe_id,
        left_join: sf in SlotFavorite,
        on:
          sf.account_id == m.account_id and sf.user_id == ^user_id and sf.date == m.date and
            sf.slot == m.slot,
        order_by: [asc: m.date, asc: m.slot],
        select: %{
          id: m.id,
          date: m.date,
          slot: m.slot,
          is_cooked: m.is_cooked,
          recipe_id: m.recipe_id,
          recipe_name: r.name,
          calories_per_serving: r.calories_per_serving,
          prep_time_minutes: r.prep_time_minutes,
          is_favorite: not is_nil(sf.id)
        }
      )
      |> Repo.all()

    meals_by_date = Enum.group_by(meals, & &1.date)

    days =
      Date.range(start_date, end_date)
      |> Enum.map(fn date ->
        day_meals = Map.get(meals_by_date, date, [])

        %{
          date: date,
          day_state: day_state(date, today, day_meals),
          has_planned_menu: day_meals != [],
          is_selected: date == selected_date
        }
      end)

    selected_meal =
      meals
      |> Enum.find(fn meal -> meal.date == selected_date and meal.slot == selected_slot end)

    %{
      start_date: start_date,
      end_date: end_date,
      today: today,
      selected_date: selected_date,
      selected_slot: selected_slot,
      days: days,
      meals: meals,
      selected_meal: selected_meal
    }
  end

  def upsert_scheduled_meal(account_id, attrs) do
    date = Map.fetch!(attrs, :date)
    slot = Map.fetch!(attrs, :slot)

    case Repo.get_by(ScheduledMeal, account_id: account_id, date: date, slot: slot) do
      nil ->
        %ScheduledMeal{}
        |> ScheduledMeal.changeset(Map.put(attrs, :account_id, account_id))
        |> Repo.insert()

      meal ->
        meal
        |> ScheduledMeal.changeset(attrs)
        |> Repo.update()
    end
  end

  def delete_scheduled_meal(account_id, date, slot) do
    case Repo.get_by(ScheduledMeal, account_id: account_id, date: date, slot: slot) do
      nil -> {:error, :not_found}
      meal -> Repo.delete(meal)
    end
  end

  @spec replace_scheduled_meals_for_range(
          Ecto.UUID.t(),
          {Date.t(), Date.t()},
          [map()]
        ) :: {:ok, %{replaced: non_neg_integer()}} | {:error, atom()}
  def replace_scheduled_meals_for_range(account_id, {from_date, to_date}, new_meals)
      when is_list(new_meals) do
    with :ok <- validate_range(from_date, to_date),
         {:ok, normalized_meals} <-
           normalize_replacement_meals(account_id, from_date, to_date, new_meals) do
      replace_range_transaction(account_id, from_date, to_date, normalized_meals)
    end
  rescue
    Postgrex.Error -> {:error, :persistence_error}
    Ecto.ConstraintError -> {:error, :persistence_error}
  end

  defp replace_range_transaction(account_id, from_date, to_date, normalized_meals) do
    Multi.new()
    |> PlanningRepo.delete_scheduled_meals_for_range(account_id, {from_date, to_date})
    |> PlanningRepo.insert_scheduled_meals(account_id, normalized_meals)
    |> Repo.transaction()
    |> map_replacement_result()
  end

  defp validate_range(%Date{} = from_date, %Date{} = to_date) do
    if Date.compare(from_date, to_date) in [:lt, :eq],
      do: :ok,
      else: {:error, :invalid_date_range}
  end

  defp validate_range(_from_date, _to_date), do: {:error, :invalid_date_range}

  defp normalize_replacement_meals(account_id, from_date, to_date, meals) do
    meals
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn
      meal, {:ok, seen, normalized} when is_map(meal) ->
        with {:ok, date} <- normalize_date(meal_value(meal, :date)),
             {:ok, slot} <- normalize_slot(meal_value(meal, :slot)),
             :ok <- validate_meal_account(account_id, meal_value(meal, :account_id)),
             :ok <- validate_meal_date(date, from_date, to_date),
             :ok <- validate_unique_slot(seen, date, slot) do
          normalized_meal =
            meal
            |> Map.take([:recipe_id, :is_cooked, :ai_generation_id])
            |> Map.put(:date, date)
            |> Map.put(:slot, slot)

          {:cont, {:ok, MapSet.put(seen, {date, slot}), [normalized_meal | normalized]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _meal, _acc ->
        {:halt, {:error, :invalid_meals}}
    end)
    |> case do
      {:ok, _seen, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp meal_value(meal, key), do: Map.get(meal, key, Map.get(meal, Atom.to_string(key)))

  defp normalize_date(%Date{} = date), do: {:ok, date}
  defp normalize_date(_date), do: {:error, :invalid_date}

  defp normalize_slot(slot) when slot in [:breakfast, :lunch, :snack, :dinner], do: {:ok, slot}
  defp normalize_slot(_slot), do: {:error, :invalid_slot}

  defp validate_meal_account(_account_id, nil), do: :ok

  defp validate_meal_account(account_id, meal_account_id) do
    if to_string(account_id) == to_string(meal_account_id),
      do: :ok,
      else: {:error, :cross_account}
  end

  defp validate_meal_date(date, from_date, to_date) do
    if Date.compare(date, from_date) != :lt and Date.compare(date, to_date) != :gt,
      do: :ok,
      else: {:error, :meal_outside_range}
  end

  defp validate_unique_slot(seen, date, slot) do
    if MapSet.member?(seen, {date, slot}), do: {:error, :duplicate_slot}, else: :ok
  end

  defp map_replacement_result({:ok, %{scheduled_meals_replacement: {count, _}}}),
    do: {:ok, %{replaced: count}}

  defp map_replacement_result({:error, _step, _reason, _changes}),
    do: {:error, :persistence_error}

  def set_is_cooked(account_id, meal_id, is_cooked) when is_boolean(is_cooked) do
    case Repo.get_by(ScheduledMeal, id: meal_id, account_id: account_id) do
      nil ->
        {:error, :not_found}

      meal ->
        meal
        |> ScheduledMeal.changeset(%{is_cooked: is_cooked})
        |> Repo.update()
    end
  end

  @doc """
    Returns the meal for a specific (account_id, date, slot) tuple.

    Returns `nil` if no meal exists for that slot.
    Includes recipe macros and favorite status via joins.
  """
  @spec get_slot_meal(pos_integer(), pos_integer(), Date.t(), atom()) :: map() | nil
  def get_slot_meal(account_id, user_id, date, slot) when is_atom(slot) do
    from(m in ScheduledMeal,
      where: m.account_id == ^account_id and m.date == ^date and m.slot == ^slot,
      left_join: r in assoc(m, :recipe),
      left_join: sf in SlotFavorite,
      on:
        sf.account_id == m.account_id and sf.user_id == ^user_id and sf.date == m.date and
          sf.slot == m.slot,
      limit: 1,
      select: %{
        id: m.id,
        date: m.date,
        slot: m.slot,
        is_cooked: m.is_cooked,
        recipe_id: m.recipe_id,
        recipe_name: r.name,
        calories_per_serving: r.calories_per_serving,
        prep_time_minutes: r.prep_time_minutes,
        is_favorite: not is_nil(sf.id)
      }
    )
    |> Repo.one()
  end

  def toggle_favorite(account_id, user_id, recipe_id) do
    case Repo.get_by(FavoriteRecipe,
           account_id: account_id,
           user_id: user_id,
           recipe_id: recipe_id
         ) do
      nil ->
        %FavoriteRecipe{}
        |> FavoriteRecipe.changeset(%{
          account_id: account_id,
          user_id: user_id,
          recipe_id: recipe_id
        })
        |> Repo.insert()
        |> case do
          {:ok, _fav} -> {:ok, true}
          {:error, cs} -> {:error, cs}
        end

      favorite ->
        case Repo.delete(favorite) do
          {:ok, _} -> {:ok, false}
          {:error, cs} -> {:error, cs}
        end
    end
  end

  defp day_state(date, today, day_meals) do
    cond do
      Date.compare(date, today) == :lt -> :past
      Date.compare(date, today) == :eq -> :today
      day_meals != [] -> :future_planned
      true -> :future_empty
    end
  end
end
