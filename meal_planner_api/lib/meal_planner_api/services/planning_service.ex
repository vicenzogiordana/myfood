defmodule MealPlannerApi.Services.PlanningService do
  @moduledoc """
  Orchestration layer for meal planning use-cases.

  Coordinates:
  - Identity resolution
  - Recipe candidate building
  - Optimization payload construction
  - Plan persistence (scheduled meals, proposals, runs)

  Delegates to OptimizerPort for optimization decisions.
  Delegates to data repos for persistence.
  """

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Optimization.OptimizerPort
  alias MealPlannerApi.Persistence.Identity

  @slots [:breakfast, :lunch, :dinner]
  @default_days ~w(monday tuesday wednesday thursday friday saturday sunday)

  # -------------------------------------------------------------------------
  # Weekly plan generation
  # -------------------------------------------------------------------------

  @type planning_user :: %{
          optional(:user_id) => pos_integer(),
          optional(:account_id) => pos_integer(),
          optional(:account_type) => atom() | String.t(),
          optional(:subscription_tier) => atom() | String.t(),
          optional(:kcal_target) => integer(),
          optional(:weekly_budget_cents) => integer(),
          optional(:user_ids) => [pos_integer()]
        }

  @type planning_params :: %{
          optional(:days) => [String.t()],
          optional(:kcal_target) => integer() | String.t(),
          optional(:weekly_budget_cents) => integer() | String.t(),
          optional(:user_ids) => [pos_integer()]
        }

  @spec generate_weekly_plan(planning_user(), planning_params(), module()) ::
          {:ok, %{plan: [map()], estimated_cost_cents: integer(), optimizer_used: boolean()}}
          | {:error, :identity_resolution_failed | :optimization_failed | :persistence_failed}
  def generate_weekly_plan(user, params \\ %{}, optimizer \\ client_module()) do
    with {:ok, identity} <- resolve_identity(user),
         {:ok, max_days} <- resolve_max_days(user),
         {:ok, selected_days} <- resolve_selected_days(params, max_days),
         true <- requested_days_valid?(params, max_days),
         candidates_by_slot <- build_candidates(user, identity),
         {:ok, result} <- run_optimizer(optimizer, selected_days, candidates_by_slot, user) do
      day_plans = build_day_plans(result.meals, selected_days)

      estimated_cost =
        result.meals
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(0, fn meal, acc -> acc + (meal["estimated_cost_cents"] || 0) end)

      {:ok,
       %{
         days: day_plans,
         estimated_cost_cents: estimated_cost,
         optimizer_used: true,
         max_planning_days: max_days,
         subscription_tier: to_string(Map.get(user, :subscription_tier, :free))
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_optimizer(module(), [String.t()], map(), planning_user()) ::
          {:ok, %{meals: [map()]}} | {:error, :optimization_failed | :optimizer_unavailable}
  def run_optimizer(OptimizerPort, days, candidates_by_slot, user) do
    run_optimizer(client_module(), days, candidates_by_slot, user)
  end

  def run_optimizer(_optimizer, [], _candidates, _user), do: {:ok, %{meals: []}}

  def run_optimizer(_optimizer, days, candidates_by_slot, user) do
    payload = build_optimization_payload(days, candidates_by_slot, user)
    client_module().select_weekly_menu(payload)
  end

  defp client_module,
    do: Application.get_env(:meal_planner_api, :planning_optimizer_client, OptimizerMock)

  @spec build_optimization_payload([String.t()], map(), planning_user()) ::
          OptimizerPort.optimizer_payload()
  def build_optimization_payload(days, candidates_by_slot, user) do
    %{
      "days" => days,
      "slots" => Enum.map(@slots, &Atom.to_string/1),
      "constraints" => %{
        "kcal_target" => parse_int(Map.get(user, :kcal_target), 2100),
        "weekly_budget_cents" => parse_int(Map.get(user, :weekly_budget_cents), 45_000),
        "account_type" => to_string(Map.get(user, :account_type, "individual")),
        "subscription_tier" => to_string(Map.get(user, :subscription_tier, "free")),
        "inventory_items" => [],
        "macro_bounds" => macro_bounds_for_user(user)
      },
      "candidates_by_slot" => candidates_by_slot
    }
  end

  # -------------------------------------------------------------------------
  # Plan persistence
  # -------------------------------------------------------------------------

  @spec save_plan(pos_integer(), pos_integer(), [map()], map()) ::
          {:ok, %{proposal_id: pos_integer(), meal_ids: [pos_integer()]}}
          | {:error, term()}
  def save_plan(account_id, user_id, meals, _metadata \\ %{}) do
    run_result =
      PlanningRepo.create_generation_run(%{
        account_id: account_id,
        user_id: user_id,
        status: :completed,
        input_context: %{"source" => "planning_service"},
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    proposal_result =
      with {:ok, run} <- run_result do
        PlanningRepo.create_proposal(%{
          generation_run_id: run.id,
          proposal_json: %{meals: meals},
          selected_at: DateTime.utc_now()
        })
      else
        err ->
          err
      end

    with {:ok, run} <- run_result,
         {:ok, proposal} <- proposal_result do
      meal_ids =
        Enum.flat_map(meals, fn meal ->
          case PlanningRepo.schedule_meal(%{
                 account_id: account_id,
                 generation_run_id: run.id,
                 planning_proposal_id: proposal.id,
                 date: parse_date(meal["day"]),
                 slot: String.to_existing_atom(meal["slot"]),
                 recipe_id: meal["recipe_id"],
                 is_cooked: false
               }) do
            {:ok, scheduled_meal} -> [scheduled_meal.id]
            {:error, _} -> []
          end
        end)

      {:ok, %{proposal_id: proposal.id, meal_ids: meal_ids}}
    else
      {:error, reason} ->
        IO.puts("DEBUG save_plan final error: #{inspect(reason)}")
        {:error, reason}
    end
  end

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
  # Candidates
  # -------------------------------------------------------------------------

  @spec build_candidates(planning_user(), map()) :: map()
  def build_candidates(user, identity) do
    user_ids = Map.get(user, :user_ids, [identity.user_id])
    account_id = identity.account_id

    # Fetch latest recipe costs for optimizer payload
    all_recipe_ids =
      Enum.flat_map(@slots, fn slot ->
        slot_str = Atom.to_string(slot)

        PlanningRepo.candidate_recipe_ids_for_slots(
          account_id,
          user_ids,
          [slot_str]
        )
      end)
      |> Enum.uniq()

    recipe_costs = PlanningRepo.latest_recipe_costs(all_recipe_ids)

    Enum.into(@slots, %{}, fn slot ->
      slot_str = Atom.to_string(slot)

      recipe_ids =
        PlanningRepo.candidate_recipe_ids_for_slots(
          account_id,
          user_ids,
          [slot_str]
        )

      recipes =
        PlanningRepo.recipes_for_ids(recipe_ids, account_id)
        |> Enum.filter(fn r -> r.slot == slot_str end)
        |> Enum.map(fn r ->
          %{
            "recipe_id" => to_string(r.id),
            "slot" => slot_str,
            "label" => r.name,
            "kcal" => 0,
            "estimated_cost_cents" => Map.get(recipe_costs, r.id, 0),
            "inventory_hit_count" => 0,
            "protein_g_per_serving" => 0,
            "carbs_g_per_serving" => 0,
            "fat_g_per_serving" => 0,
            "calories_per_serving" => 0
          }
        end)

      {slot_str, recipes}
    end)
  end

  # -------------------------------------------------------------------------
  # Cooking sessions
  # -------------------------------------------------------------------------

  @spec start_cooking_session(pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, :meal_not_found}
  def start_cooking_session(account_id, user_id, scheduled_meal_id) do
    meal = PlanningRepo.get_scheduled_meal_for_account(account_id, scheduled_meal_id)

    case meal do
      nil ->
        {:error, :meal_not_found}

      _ ->
        {:ok, session} =
          PlanningRepo.create_cooking_session(%{
            account_id: account_id,
            user_id: user_id,
            scheduled_meal_id: scheduled_meal_id,
            status: :in_progress,
            started_at: DateTime.utc_now()
          })

        {:ok,
         %{
           session_id: session.id,
           meal_id: scheduled_meal_id,
           recipe: serialize_recipe(meal.recipe)
         }}
    end
  end

  @spec add_chat_message(pos_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def add_chat_message(session_id, content) do
    {:ok, msg} =
      PlanningRepo.add_chat_message(%{
        cooking_session_id: session_id,
        role: :user,
        content: content,
        sent_at: DateTime.utc_now()
      })

    {:ok, %{message_id: msg.id, content: msg.content}}
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp resolve_identity(user) do
    Identity.ensure_persistent_identity(user)
  end

  defp resolve_max_days(user) do
    tier = Map.get(user, :subscription_tier, :free)

    max =
      case tier do
        :premium -> 7
        "premium" -> 7
        _ -> 5
      end

    {:ok, max}
  end

  defp macro_bounds_for_user(_user) do
    %{
      "protein_g" => %{"min" => 100.0, "max" => 150.0},
      "carbs_g" => %{"min" => 225.0, "max" => 325.0},
      "fat_g" => %{"min" => 44.44, "max" => 77.78},
      "calories" => %{"min" => 1800.0, "max" => 2500.0}
    }
  end

  defp resolve_selected_days(params, max_days) do
    requested = Map.get(params, "days", @default_days)
    # Handle both list (["monday", "tuesday"]) and integer ("8" or 8)
    normalized =
      cond do
        is_list(requested) ->
          requested

        is_binary(requested) ->
          case Integer.parse(requested) do
            {n, ""} -> List.first(@default_days) |> next_days_until(n)
            :error -> @default_days
          end

        is_integer(requested) ->
          List.first(@default_days) |> next_days_until(requested)

        true ->
          @default_days
      end

    selected = Enum.take(normalized, max_days)
    {:ok, selected}
  end

  defp requested_days_valid?(params, max_days) do
    requested = Map.get(params, "days")

    if is_nil(requested) do
      true
    else
      count =
        cond do
          is_list(requested) ->
            length(requested)

          is_binary(requested) ->
            case Integer.parse(requested) do
              {n, ""} -> n
              :error -> length(@default_days)
            end

          is_integer(requested) ->
            requested

          true ->
            length(@default_days)
        end

      if count > max_days do
        {:error, :exceeds_max_planning_days}
      else
        true
      end
    end
  end

  defp next_days_until(start_day, count) do
    day_atoms = [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]
    start_idx = Enum.find_index(day_atoms, &(&1 == start_day)) || 0

    Enum.map(0..(count - 1), fn i ->
      day_atom = Enum.at(day_atoms, rem(start_idx + i, 7))
      Atom.to_string(day_atom)
    end)
  end

  defp build_day_plans(meals, days) do
    Enum.map(days, fn day ->
      day_meals = Enum.filter(meals, &(&1["day"] == day))
      %{day: day, meals: day_meals}
    end)
  end

  defp parse_date("monday"), do: next_weekday(:monday)
  defp parse_date("tuesday"), do: next_weekday(:tuesday)
  defp parse_date("wednesday"), do: next_weekday(:wednesday)
  defp parse_date("thursday"), do: next_weekday(:thursday)
  defp parse_date("friday"), do: next_weekday(:friday)
  defp parse_date("saturday"), do: next_weekday(:saturday)
  defp parse_date("sunday"), do: next_weekday(:sunday)
  defp parse_date(_), do: Date.utc_today() |> Date.add(1)

  defp next_weekday(target) do
    today = Date.utc_today()
    today_weekday = Date.day_of_week(today)

    target_weekday =
      case target do
        :monday -> 1
        :tuesday -> 2
        :wednesday -> 3
        :thursday -> 4
        :friday -> 5
        :saturday -> 6
        :sunday -> 7
      end

    days_ahead = target_weekday - today_weekday
    days_ahead = if days_ahead <= 0, do: days_ahead + 7, else: days_ahead
    Date.add(today, days_ahead)
  end

  defp serialize_scheduled_meal(meal) do
    %{
      id: meal.id,
      date: meal.date,
      slot: Atom.to_string(meal.slot),
      recipe_id: meal.recipe_id,
      is_cooked: meal.is_cooked
    }
  end

  defp serialize_recipe(nil), do: nil

  defp serialize_recipe(recipe) do
    %{
      id: recipe.id,
      name: recipe.name,
      prep_time_minutes: recipe.prep_time_minutes,
      calories_per_serving: recipe.calories_per_serving
    }
  end

  defp parse_int(nil, f), do: f
  defp parse_int(value, _f) when is_integer(value), do: value

  defp parse_int(value, f) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> f
    end
  end

  defp parse_int(_, _), do: nil

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
