defmodule MealPlannerApi.Planning.WeeklyPlan do
  @moduledoc """
  In-memory weekly meal plan representation.
  """

  @enforce_keys [:account_type, :subscription_tier, :days]
  defstruct [
    :account_type,
    :subscription_tier,
    :days,
    :budget,
    :budget_within_limit,
    :estimated_total_cost_cents,
    :inventory_items,
    :max_planning_days,
    notes: []
  ]

  @type meal :: %{
          slot: atom(),
          label: String.t(),
          kcal: non_neg_integer(),
          estimated_cost_cents: non_neg_integer(),
          inventory_hit_count: non_neg_integer()
        }
  @type day_plan :: %{day: String.t(), meals: [meal()]}

  @type t :: %__MODULE__{
          account_type: :individual | :group,
          subscription_tier: :free | :premium,
          days: [day_plan()],
          budget: map(),
          budget_within_limit: boolean(),
          estimated_total_cost_cents: non_neg_integer(),
          inventory_items: [String.t()],
          max_planning_days: pos_integer(),
          notes: [String.t()]
        }
end
