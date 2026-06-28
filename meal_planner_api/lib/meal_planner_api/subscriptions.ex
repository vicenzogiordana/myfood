defmodule MealPlannerApi.Subscriptions do
  @moduledoc """
  Subscription plans backed by PostgreSQL.

  Phase A — Tenancy Refactor:

    * PR 1 (task 1.2): the legacy `:account_type` taxonomy
      (`:individual | :group`) was dropped from the `Account` schema;
      the canonical `:plan` Ecto.Enum (`:individual | :family_4 |
      :family_6 | :trial`) is now the source of truth.
    * PR 2a (task 2.11): `policy_for_account/1` reads `account.plan`
      and resolves through `subscription_plans.name`. `:family_6` and
      `:trial` rows were seeded in PR 1 (design §2.6 / Q10). `:trial`
      reuses the `:family_6` seat cap (6) until the trial-expiration
      timer ships in the follow-up change `tenancy-v2-hardening`.
    * PR 1's `default_plan_name_for_account_type/1` was renamed to
      `default_plan_name_for_plan/1` (operates on the new enum).

  This module is the single source of truth for plan → policy
  resolution. The Application layer (`AccountsMembership`) calls it
  for seat-cap arithmetic; the Web layer reads it for billing surfaces
  in PR 3.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Subscriptions.Plan

  @default_individual_plan "individual"
  @default_group_plan "family_4"

  @spec normalize_tier(term()) :: :free | :premium
  def normalize_tier("premium"), do: :premium
  def normalize_tier(:premium), do: :premium
  def normalize_tier(_), do: :free

  @spec get_plan_by_name(binary()) :: {:ok, Plan.t()} | {:error, :plan_not_found}
  def get_plan_by_name(name) when is_binary(name) do
    case Repo.get_by(Plan, name: name) do
      %Plan{} = plan -> {:ok, plan}
      nil -> {:error, :plan_not_found}
    end
  end

  @spec get_plan_for_account(binary()) ::
          {:ok, Plan.t()} | {:error, :account_not_found | :plan_not_found}
  def get_plan_for_account(account_id) when is_binary(account_id) do
    query =
      from(a in Account,
        where: a.id == ^account_id,
        preload: [:subscription_plan],
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        {:error, :account_not_found}

      %Account{subscription_plan: %Plan{} = plan} ->
        {:ok, plan}

      %Account{plan: plan} ->
        plan_atom = plan_atom_from_value(plan)
        get_plan_by_name(default_plan_name_for_plan(plan_atom))
    end
  end

  @spec policy_for_account(binary()) :: map()
  def policy_for_account(account_id) when is_binary(account_id) do
    case get_plan_for_account(account_id) do
      {:ok, plan} -> serialize_policy(plan)
      {:error, reason} -> %{error: Atom.to_string(reason)}
    end
  end

  @spec policy_for(map() | binary()) :: map()
  def policy_for(%{account_id: account_id}) when is_binary(account_id),
    do: policy_for_account(account_id)

  def policy_for(account_id) when is_binary(account_id), do: policy_for_account(account_id)
  def policy_for(_), do: %{error: "account_not_found"}

  @spec max_planning_days(binary()) ::
          {:ok, pos_integer()} | {:error, :account_not_found | :plan_not_found}
  def max_planning_days(account_id) when is_binary(account_id) do
    with {:ok, plan} <- get_plan_for_account(account_id) do
      {:ok, plan.max_planning_days}
    end
  end

  @spec default_plan_name_for_plan(atom() | binary()) :: binary()
  def default_plan_name_for_plan(:family_4), do: @default_group_plan
  def default_plan_name_for_plan(:family_6), do: @default_group_plan
  def default_plan_name_for_plan(:trial), do: @default_group_plan
  def default_plan_name_for_plan("family_4"), do: @default_group_plan
  def default_plan_name_for_plan("family_6"), do: @default_group_plan
  def default_plan_name_for_plan("trial"), do: @default_group_plan
  def default_plan_name_for_plan(_), do: @default_individual_plan

  @spec ensure_default_plan_id(atom() | binary()) ::
          {:ok, Ecto.UUID.t()} | {:error, :plan_not_found}
  def ensure_default_plan_id(plan) do
    with {:ok, plan_row} <- get_plan_by_name(default_plan_name_for_plan(plan)) do
      {:ok, plan_row.id}
    end
  end

  defp serialize_policy(%Plan{} = plan) do
    %{
      name: plan.name,
      max_users: plan.max_users,
      max_planning_days: plan.max_planning_days,
      revenuecat_entitlement_id: plan.revenuecat_entitlement_id
    }
  end

  # Accept string or atom form of plan (the schema casts Ecto.Enum to atom,
  # but Repo.get/preload may surface the raw DB string).
  defp plan_atom_from_value(plan) when is_atom(plan), do: plan
  defp plan_atom_from_value(plan) when is_binary(plan), do: String.to_existing_atom(plan)
end
