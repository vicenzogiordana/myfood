defmodule MealPlannerApi.Subscriptions do
  @moduledoc """
  Mock subscription policies for freemium constraints.
  """

  @type tier :: :free | :premium

  @spec normalize_tier(term()) :: tier()
  def normalize_tier("premium"), do: :premium
  def normalize_tier(:premium), do: :premium
  def normalize_tier(_), do: :free

  @spec policy_for(tier()) :: map()
  def policy_for(:premium) do
    %{
      tier: :premium,
      max_planning_days: 7,
      cooking_assistant: :unlimited,
      advanced_price_comparison: true,
      monthly_price_usd: 3
    }
  end

  def policy_for(:free) do
    %{
      tier: :free,
      max_planning_days: 3,
      cooking_assistant: :limited,
      advanced_price_comparison: false,
      monthly_price_usd: 0
    }
  end

  @spec max_planning_days(tier()) :: pos_integer()
  def max_planning_days(tier) do
    tier
    |> normalize_tier()
    |> policy_for()
    |> Map.fetch!(:max_planning_days)
  end
end
