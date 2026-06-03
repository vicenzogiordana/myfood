defmodule MealPlannerApi.Services.SubscriptionService do
  @moduledoc """
  Subscription policy service.
  Thin wrapper around the Subscriptions persistence module.
  """

  alias MealPlannerApi.Subscriptions

  @spec normalize_tier(term()) :: :free | :premium
  def normalize_tier("premium"), do: :premium
  def normalize_tier(:premium), do: :premium
  def normalize_tier(_), do: :free

  @spec policy_for(binary()) :: map()
  def policy_for(account_id) when is_binary(account_id),
    do: Subscriptions.policy_for_account(account_id)

  @spec policy_for_account(binary()) :: map()
  def policy_for_account(account_id) when is_binary(account_id),
    do: Subscriptions.policy_for_account(account_id)

  @spec get_plan_for_account(binary()) :: {:ok, Subscriptions.Plan.t()} | {:error, term()}
  def get_plan_for_account(account_id) when is_binary(account_id),
    do: Subscriptions.get_plan_for_account(account_id)

  @spec max_planning_days(binary()) :: {:ok, pos_integer()} | {:error, term()}
  def max_planning_days(account_id) when is_binary(account_id),
    do: Subscriptions.max_planning_days(account_id)

  @spec ensure_default_plan_id(atom() | binary()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def ensure_default_plan_id(account_type),
    do: Subscriptions.ensure_default_plan_id(account_type)
end
