defmodule MealPlannerApi.Services.BudgetService do
  @moduledoc """
  Budget resolution service.

  Resolves weekly budget limits based on account type and subscription tier.
  """

  alias MealPlannerApi.Data.AccountRepo
  alias MealPlannerApi.Budgets.Budget

  @spec resolve(map()) :: Budget.t()
  def resolve(user) do
    account_id = Map.get(user, :account_id)
    tier = Map.get(user, :subscription_tier, :free)
    override = Map.get(user, :weekly_budget_cents)

    limit =
      if override && is_integer(override) && override > 0 do
        override
      else
        resolve_default_limit(account_id, tier)
      end

    %Budget{
      account_id: account_id,
      weekly_limit_cents: limit,
      currency: Map.get(user, :currency, "ARS")
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

  defp resolve_default_limit(account_id, tier) when is_binary(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, _} ->
        case AccountRepo.get_account(account_id) do
          %{default_budget_cents: cents} when is_integer(cents) and cents >= 0 -> cents
          _ -> tier_default_limit(tier)
        end

      :error ->
        tier_default_limit(tier)
    end
  end

  defp resolve_default_limit(_account_id, tier), do: tier_default_limit(tier)

  defp tier_default_limit(:premium), do: 85_000
  defp tier_default_limit("premium"), do: 85_000
  defp tier_default_limit(_), do: 45_000
end
