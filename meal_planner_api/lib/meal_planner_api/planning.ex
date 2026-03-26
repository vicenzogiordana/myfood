defmodule MealPlannerApi.Planning do
  @moduledoc """
  Planning context containing meal planning use-cases.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Budgets
  alias MealPlannerApi.Inventory
  alias MealPlannerApi.Planning.WeeklyPlan
  alias MealPlannerApi.Persistence.Catalog.Recipe
  alias MealPlannerApi.Persistence.Catalog.RecipeDailyCost
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning, as: PlanningPersistence
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions

  @days ~w(monday tuesday wednesday thursday friday saturday sunday)
  @planning_slots [:breakfast, :lunch, :dinner]

  @spec weekly_plan_for(map(), map()) :: WeeklyPlan.t()
  def weekly_plan_for(user, params \\ %{}) when is_map(user) and is_map(params) do
    account_type = Map.get(user, :account_type, :individual)
    tier = Map.get(user, :subscription_tier, :free)

    kcal_target = parse_int(Map.get(params, "kcal_target"), 2100)
    budget = Budgets.resolve_for(user, params)
    inventory = Inventory.available_for(user, params)
    max_days = Subscriptions.max_planning_days(tier)
    selected_days = Enum.take(@days, max_days)
    identity = resolve_identity(user)

    candidates_by_slot =
      build_candidates_by_slot(identity, inventory, kcal_target, account_type)

    optimization_payload =
      build_optimization_payload(
        selected_days,
        kcal_target,
        budget.weekly_limit_cents,
        account_type,
        tier,
        candidates_by_slot,
        inventory
      )

    day_plans =
      build_day_plans_from_optimizer(
        selected_days,
        optimization_payload,
        candidates_by_slot,
        account_type,
        kcal_target,
        inventory
      )

    estimated_cost_cents =
      day_plans
      |> Enum.flat_map(& &1.meals)
      |> Enum.reduce(0, fn meal, acc -> acc + meal.estimated_cost_cents end)

    budget_ok? = Budgets.within_limit?(budget, estimated_cost_cents)

    notes =
      if account_type == :group do
        [
          "Group mode: meals include shareable portions",
          "Shopping list is optimized for bulk prep"
        ]
      else
        ["Individual mode: portions and macros are single-user tuned"]
      end

    notes =
      notes ++
        [
          "Budget mode: estimated #{estimated_cost_cents} #{budget.currency} cents / limit #{budget.weekly_limit_cents}",
          "Inventory priority ingredients: #{Enum.join(Inventory.names(inventory), ", ")}",
          "Subscription tier #{tier}: max #{max_days} planning days"
        ]

    notes =
      if budget_ok? do
        notes
      else
        ["Budget exceeded: reduce premium ingredients or increase budget."] ++ notes
      end

    %WeeklyPlan{
      account_type: account_type,
      subscription_tier: tier,
      days: day_plans,
      notes: notes,
      budget: Budgets.serialize(budget),
      budget_within_limit: budget_ok?,
      estimated_total_cost_cents: estimated_cost_cents,
      inventory_items: Inventory.names(inventory),
      max_planning_days: max_days
    }
  end

  @spec serialize_plan(WeeklyPlan.t()) :: map()
  def serialize_plan(%WeeklyPlan{} = plan) do
    %{
      account_type: plan.account_type,
      subscription_tier: plan.subscription_tier,
      days: plan.days,
      notes: plan.notes,
      budget: plan.budget,
      budget_within_limit: plan.budget_within_limit,
      estimated_total_cost_cents: plan.estimated_total_cost_cents,
      inventory_items: plan.inventory_items,
      max_planning_days: plan.max_planning_days
    }
  end

  defp build_day_plans_from_optimizer(
         selected_days,
         optimization_payload,
         candidates_by_slot,
         account_type,
         kcal_target,
         inventory
       ) do
    case optimizer_client().select_weekly_menu(optimization_payload) do
      {:ok, optimizer_result} ->
        case parse_optimizer_result(optimizer_result, selected_days, candidates_by_slot) do
          {:ok, day_plans} ->
            day_plans

          {:error, _} ->
            fallback_day_plans(
              selected_days,
              candidates_by_slot,
              account_type,
              kcal_target,
              inventory
            )
        end

      {:error, _} ->
        fallback_day_plans(
          selected_days,
          candidates_by_slot,
          account_type,
          kcal_target,
          inventory
        )
    end
  end

  defp build_optimization_payload(
         selected_days,
         kcal_target,
         budget_limit_cents,
         account_type,
         tier,
         candidates_by_slot,
         inventory
       ) do
    macro_bounds = macro_bounds_for(kcal_target)

    %{
      "days" => selected_days,
      "slots" => Enum.map(@planning_slots, &Atom.to_string/1),
      "constraints" => %{
        "kcal_target" => kcal_target,
        "weekly_budget_cents" => budget_limit_cents,
        "account_type" => Atom.to_string(account_type),
        "subscription_tier" => Atom.to_string(tier),
        "inventory_items" => Inventory.names(inventory),
        "macro_bounds" => macro_bounds
      },
      "candidates_by_slot" =>
        Map.new(candidates_by_slot, fn {slot, candidates} ->
          {Atom.to_string(slot), Enum.map(candidates, &candidate_to_optimizer_payload/1)}
        end)
    }
  end

  defp parse_optimizer_result(result, selected_days, candidates_by_slot) when is_map(result) do
    candidate_lookup = build_candidate_lookup(candidates_by_slot)
    days_set = MapSet.new(selected_days)

    with meals when is_list(meals) <- Map.get(result, "meals"),
         true <- meals != [] do
      day_plans =
        selected_days
        |> Enum.map(fn day ->
          day_meals =
            meals
            |> Enum.filter(fn meal -> Map.get(meal, "day") == day end)
            |> Enum.map(fn meal ->
              slot = normalize_slot(Map.get(meal, "slot"))
              recipe_id = Map.get(meal, "recipe_id")

              case Map.get(candidate_lookup, {slot, recipe_id}) do
                nil -> fallback_candidate(slot)
                candidate -> candidate
              end
            end)

          %{
            day: day,
            meals: ensure_all_slots(day_meals, candidates_by_slot)
          }
        end)

      if Enum.all?(meals, fn meal -> MapSet.member?(days_set, Map.get(meal, "day")) end) do
        {:ok, day_plans}
      else
        {:error, :invalid_days}
      end
    else
      _ -> {:error, :invalid_optimizer_result}
    end
  end

  defp parse_optimizer_result(_, _selected_days, _candidates_by_slot),
    do: {:error, :invalid_optimizer_result}

  defp ensure_all_slots(day_meals, candidates_by_slot) do
    day_by_slot = Map.new(day_meals, fn meal -> {meal.slot, meal} end)

    Enum.map(@planning_slots, fn slot ->
      case Map.get(day_by_slot, slot) do
        nil ->
          case Map.get(candidates_by_slot, slot, []) do
            [candidate | _] -> candidate
            [] -> fallback_candidate(slot)
          end

        meal ->
          meal
      end
    end)
  end

  defp fallback_day_plans(
         selected_days,
         candidates_by_slot,
         _account_type,
         _kcal_target,
         _inventory
       ) do
    selected_days
    |> Enum.with_index()
    |> Enum.map(fn {day, day_index} ->
      meals =
        Enum.map(@planning_slots, fn slot ->
          candidates = Map.get(candidates_by_slot, slot, [])

          case candidates do
            [] -> fallback_candidate(slot)
            _ -> Enum.at(candidates, rem(day_index, length(candidates)))
          end
        end)

      %{day: day, meals: meals}
    end)
  end

  defp build_candidates_by_slot(identity, inventory, kcal_target, account_type) do
    recipes_by_slot =
      Enum.into(@planning_slots, %{}, fn slot ->
        {slot, load_candidate_recipes(identity, slot)}
      end)

    recipe_ids =
      recipes_by_slot
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    recipe_costs = load_recipe_costs(recipe_ids)

    Enum.into(@planning_slots, %{}, fn slot ->
      recipes = Map.get(recipes_by_slot, slot, [])

      candidates =
        Enum.map(recipes, fn recipe ->
          to_candidate(recipe, slot, recipe_costs, inventory, kcal_target, account_type)
        end)

      {slot, if(candidates == [], do: [fallback_candidate(slot)], else: candidates)}
    end)
  end

  defp load_candidate_recipes(%{account_id: account_id, user_id: user_id}, slot)
       when is_binary(account_id) and is_binary(user_id) do
    recipe_ids = PlanningPersistence.candidate_recipe_ids_for_users(account_id, [user_id], slot)

    case recipe_ids do
      [] ->
        []

      ids ->
        from(r in Recipe,
          where: r.id in ^ids,
          where: ^slot in r.suitable_for_slots,
          preload: [recipe_ingredients: [:ingredient], daily_costs: []]
        )
        |> Repo.all()
    end
  end

  defp load_candidate_recipes(_identity, _slot), do: []

  defp load_recipe_costs(recipe_ids) when is_list(recipe_ids) do
    recipe_ids = Enum.uniq(Enum.filter(recipe_ids, &is_binary/1))

    if recipe_ids == [] do
      %{}
    else
      today = Date.utc_today()

      rows =
        from(c in RecipeDailyCost,
          where: c.recipe_id in ^recipe_ids,
          order_by: [desc: c.date, asc: c.total_cents_ars],
          select: {c.recipe_id, c.date, c.total_cents_ars}
        )
        |> Repo.all()

      today_costs =
        rows
        |> Enum.filter(fn {_recipe_id, date, _cents} -> date == today end)
        |> Enum.reduce(%{}, fn {recipe_id, _date, cents}, acc ->
          Map.put_new(acc, recipe_id, cents)
        end)

      historical_costs =
        rows
        |> Enum.reject(fn {_recipe_id, date, _cents} -> date == today end)
        |> Enum.reduce(%{}, fn {recipe_id, _date, cents}, acc ->
          Map.put_new(acc, recipe_id, cents)
        end)

      Map.merge(historical_costs, today_costs)
    end
  end

  defp load_recipe_costs(_), do: %{}

  defp to_candidate(recipe, slot, recipe_costs, inventory, kcal_target, account_type) do
    recipe_name = recipe.name || fallback_label(slot, account_type)
    inventory_hits = Inventory.count_hits(recipe_name, inventory)
    default_kcal = default_kcal_for(slot, kcal_target)

    %{
      recipe_id: recipe.id,
      slot: slot,
      label: recipe_name,
      kcal: recipe.calories_per_serving || default_kcal,
      estimated_cost_cents: Map.get(recipe_costs, recipe.id, fallback_cost_for(slot)),
      inventory_hit_count: inventory_hits,
      protein_g_per_serving: decimal_to_float(recipe.protein_g_per_serving),
      carbs_g_per_serving: decimal_to_float(recipe.carbs_g_per_serving),
      fat_g_per_serving: decimal_to_float(recipe.fat_g_per_serving)
    }
  end

  defp fallback_candidate(slot) do
    %{
      recipe_id: nil,
      slot: slot,
      label: fallback_label(slot, :individual),
      kcal: default_kcal_for(slot, 2100),
      estimated_cost_cents: fallback_cost_for(slot),
      inventory_hit_count: 0,
      protein_g_per_serving: 0.0,
      carbs_g_per_serving: 0.0,
      fat_g_per_serving: 0.0
    }
  end

  defp build_candidate_lookup(candidates_by_slot) do
    candidates_by_slot
    |> Enum.flat_map(fn {_slot, candidates} ->
      Enum.map(candidates, fn candidate ->
        {{candidate.slot, candidate.recipe_id}, candidate}
      end)
    end)
    |> Map.new()
  end

  defp candidate_to_optimizer_payload(candidate) do
    %{
      "recipe_id" => candidate.recipe_id,
      "slot" => Atom.to_string(candidate.slot),
      "label" => candidate.label,
      "kcal" => candidate.kcal,
      "estimated_cost_cents" => candidate.estimated_cost_cents,
      "inventory_hit_count" => candidate.inventory_hit_count,
      "protein_g_per_serving" => candidate.protein_g_per_serving,
      "carbs_g_per_serving" => candidate.carbs_g_per_serving,
      "fat_g_per_serving" => candidate.fat_g_per_serving
    }
  end

  defp fallback_label(:breakfast, _account_type), do: "breakfast suggestion"
  defp fallback_label(:lunch, :group), do: "family lunch"
  defp fallback_label(:lunch, _account_type), do: "protein lunch"
  defp fallback_label(:dinner, _account_type), do: "light dinner"
  defp fallback_label(_slot, _account_type), do: "meal suggestion"

  defp fallback_cost_for(:breakfast), do: 2_100
  defp fallback_cost_for(:lunch), do: 4_100
  defp fallback_cost_for(:dinner), do: 3_500
  defp fallback_cost_for(_slot), do: 3_000

  defp default_kcal_for(:breakfast, kcal_target), do: trunc(kcal_target * 0.25)
  defp default_kcal_for(:lunch, kcal_target), do: trunc(kcal_target * 0.35)
  defp default_kcal_for(:dinner, kcal_target), do: trunc(kcal_target * 0.30)
  defp default_kcal_for(_slot, kcal_target), do: trunc(kcal_target * 0.33)

  defp macro_bounds_for(kcal_target) when is_integer(kcal_target) and kcal_target > 0 do
    %{
      "protein_g" => macro_range(kcal_target, 0.20, 0.30, 4.0),
      "carbs_g" => macro_range(kcal_target, 0.45, 0.65, 4.0),
      "fat_g" => macro_range(kcal_target, 0.20, 0.35, 9.0)
    }
  end

  defp macro_bounds_for(_kcal_target), do: macro_bounds_for(2100)

  defp macro_range(kcal_target, min_ratio, max_ratio, kcal_per_gram) do
    %{
      "min" => Float.round(kcal_target * min_ratio / kcal_per_gram, 2),
      "max" => Float.round(kcal_target * max_ratio / kcal_per_gram, 2)
    }
  end

  defp decimal_to_float(nil), do: 0.0
  defp decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_to_float(value) when is_number(value), do: value * 1.0
  defp decimal_to_float(_), do: 0.0

  defp normalize_slot("breakfast"), do: :breakfast
  defp normalize_slot("lunch"), do: :lunch
  defp normalize_slot("dinner"), do: :dinner
  defp normalize_slot(slot) when is_atom(slot), do: slot
  defp normalize_slot(_), do: :lunch

  defp resolve_identity(user) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, ids} -> ids
      _ -> %{account_id: Map.get(user, :account_id), user_id: Map.get(user, :id)}
    end
  end

  defp optimizer_client do
    Application.get_env(
      :meal_planner_api,
      :planning_optimizer_client,
      MealPlannerApi.Planning.MockOptimizerClient
    )
  end

  defp parse_int(nil, fallback), do: fallback

  defp parse_int(value, _fallback) when is_integer(value), do: value

  defp parse_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> fallback
    end
  end

  defp parse_int(_, fallback), do: fallback
end
