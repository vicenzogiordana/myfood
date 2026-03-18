defmodule MealPlannerApi.Budgets do
  @moduledoc """
  Budget context with mock account constraints.
  """

  alias MealPlannerApi.Accounts.User
  alias MealPlannerApi.Budgets.Budget

  @spec resolve_for(User.t(), map()) :: Budget.t()
  def resolve_for(%User{account_id: account_id, subscription_tier: tier}, params \\ %{}) do
    default_limit = if tier == :premium, do: 85_000, else: 45_000

    %Budget{
      account_id: account_id,
      weekly_limit_cents: parse_int(Map.get(params, "weekly_budget_cents"), default_limit),
      currency: Map.get(params, "currency", "ARS")
    }
  end

  @spec within_limit?(Budget.t(), non_neg_integer()) :: boolean()
  def within_limit?(%Budget{weekly_limit_cents: limit}, estimated_cents)
      when is_integer(estimated_cents) and estimated_cents >= 0 do
    estimated_cents <= limit
  end

  @spec serialize(Budget.t()) :: map()
  def serialize(%Budget{} = budget) do
    %{
      account_id: budget.account_id,
      weekly_limit_cents: budget.weekly_limit_cents,
      currency: budget.currency
    }
  end

  defp parse_int(nil, fallback), do: fallback
  defp parse_int(value, _fallback) when is_integer(value), do: value

  defp parse_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> fallback
    end
  end

  defp parse_int(_, fallback), do: fallback
end
