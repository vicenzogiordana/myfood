defmodule MealPlannerApiWeb.ChannelCapability do
  @moduledoc """
  Realtime capability guard for `revenuecat-access-enforcement` (PR 4 /
  Phase 4).

  Mirrors `MealPlannerApiWeb.Plugs.EnforceCapability` for HTTP. Channels
  call `authorize/1` after the membership/topic check in `join/3` and
  short-circuit to `{:error, :subscription_required}}` when enforcement
  is enabled AND `AccountAccess.eligible?/1` returns `false`.

  The rollout flag is the same `:revenuecat_access_enforcement` binding
  the HTTP plug reads — flipping the flag flips both transports at once
  (design §"Migration / Rollout", `config/{runtime,test}.exs`).

  When the flag is off (the rollout default), `authorize/1` is a no-op
  so existing channel clients keep working through the staged rollout.
  """

  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.Persistence.Accounts.AccountMembership

  @spec authorize(AccountMembership.t()) :: :ok | {:error, :subscription_required}
  def authorize(%AccountMembership{account_id: account_id}) do
    cond do
      not enforcement_enabled?() -> :ok
      not AccountAccess.eligible?(account_id) -> {:error, :subscription_required}
      true -> :ok
    end
  end

  @doc """
  Returns `true` when the shared `:revenuecat_access_enforcement` flag
  is on. Public so channel tests can flip it without poking at the
  plug.
  """
  @spec enforcement_enabled?() :: boolean()
  def enforcement_enabled? do
    Application.get_env(:meal_planner_api, :revenuecat_access_enforcement, false) == true
  end
end
