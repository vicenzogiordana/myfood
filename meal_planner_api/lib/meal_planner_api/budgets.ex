defmodule MealPlannerApi.Budgets do
  @moduledoc """
  Budget context with account-based constraints.
  """

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Budgets.Budget
  alias MealPlannerApi.Persistence.Accounts.Account

  @spec resolve_for(map(), map()) :: Budget.t()
  def resolve_for(user, params \\ %{}) when is_map(user) do
    account_id = Map.get(user, :account_id)
    tier = Map.get(user, :subscription_tier, :free)
    default_limit = resolve_default_limit(account_id, tier)

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

  defp resolve_default_limit(account_id, tier) when is_binary(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, _} ->
        case Repo.get(Account, account_id) do
          %Account{default_budget_cents: cents} when is_integer(cents) and cents >= 0 -> cents
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
