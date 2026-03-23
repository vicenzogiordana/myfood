defmodule MealPlannerApi.Persistence.Calendar do
  @moduledoc "Calendar-oriented read/write operations for Home view with realtime collaboration."

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Catalog.FavoriteRecipe
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
          is_favorite: not is_nil(f.id)
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
