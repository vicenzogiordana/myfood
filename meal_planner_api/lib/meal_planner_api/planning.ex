defmodule MealPlannerApi.Planning do
  @moduledoc """
  Planning context containing meal planning use-cases.
  """

  alias MealPlannerApi.Accounts.User
  alias MealPlannerApi.Budgets
  alias MealPlannerApi.Inventory
  alias MealPlannerApi.Planning.WeeklyPlan
  alias MealPlannerApi.Subscriptions

  @days ~w(monday tuesday wednesday thursday friday saturday sunday)
  @meal_catalog [
    %{slot: :breakfast, label: "oats and yogurt bowl", kcal_ratio: 0.25, cost_cents: 2_100},
    %{slot: :lunch, label: "chicken rice broccoli", kcal_ratio: 0.35, cost_cents: 4_100},
    %{slot: :dinner, label: "egg fried rice", kcal_ratio: 0.30, cost_cents: 3_500}
  ]

  @spec weekly_plan_for(User.t(), map()) :: WeeklyPlan.t()
  def weekly_plan_for(
        %User{account_type: account_type, subscription_tier: tier} = user,
        params \\ %{}
      )
      when is_map(params) do
    kcal_target = parse_int(Map.get(params, "kcal_target"), 2100)
    budget = Budgets.resolve_for(user, params)
    inventory = Inventory.available_for(user, params)
    max_days = Subscriptions.max_planning_days(tier)
    selected_days = Enum.take(@days, max_days)

    day_plans =
      Enum.map(selected_days, &build_day_plan(&1, kcal_target, account_type, inventory))

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

  defp build_day_plan(day, kcal_target, account_type, inventory) do
    lunch_label = if account_type == :group, do: "family bowl", else: "protein bowl"

    meals =
      Enum.map(@meal_catalog, fn meal ->
        label = if meal.slot == :lunch, do: lunch_label, else: meal.label
        inventory_hits = Inventory.count_hits(label, inventory)

        %{
          slot: meal.slot,
          label: label,
          kcal: trunc(kcal_target * meal.kcal_ratio),
          estimated_cost_cents: meal.cost_cents,
          inventory_hit_count: inventory_hits
        }
      end)

    %{
      day: day,
      meals: meals
    }
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
