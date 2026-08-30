defmodule MealPlannerApiWeb.ChannelHelpers do
  @moduledoc """
  Shared helper functions for channel tests.
  """

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Repo

  @doc """
  Creates a test user and account, then generates a JWT token.

  Returns `{:ok, user, account, token}`.
  """
  @spec issue_identity_and_token(String.t(), String.t()) ::
          {:ok, MealPlannerApi.Accounts.User.t(), MealPlannerApi.Accounts.Account.t(), String.t()}
  def issue_identity_and_token(user_id, account_id) do
    with {:ok, %{user: user, account: account}} <-
           Accounts.find_or_create_identity(%{"user_id" => user_id, "account_id" => account_id}),
         {:ok, token, _claims} <-
           Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
             token_type: "access"
           ) do
      {:ok, user, account, token}
    end
  end

  # Phase 4 — `revenuecat-access-enforcement` realtime enforcement
  # (task 4.1): shared helper to persist a trial window on a seeded
  # Account so `AccountAccess.eligible?/1` evaluates `:eligible` or
  # `:expired` at `join/3` time. Mirrors the helper in
  # `enforce_capability_test.exs` for the HTTP plug.
  @doc """
  Persists a trial window on the given Account. `:eligible` writes a
  window that covers `now`; `:expired` writes a window 30 days in the
  past so the trial is well over.
  """
  @spec persist_trial_window!(PersistenceAccount.t(), :eligible | :expired) ::
          PersistenceAccount.t()
  def persist_trial_window!(%PersistenceAccount{} = account, :eligible) do
    started = DateTime.utc_now()
    ends = DateTime.add(started, 7 * 86_400, :second)

    {:ok, updated} =
      account
      |> PersistenceAccount.changeset(%{trial_started_at: started, trial_ends_at: ends})
      |> Repo.update()

    updated
  end

  def persist_trial_window!(%PersistenceAccount{} = account, :expired) do
    past = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    {:ok, updated} =
      account
      |> PersistenceAccount.changeset(%{trial_started_at: past, trial_ends_at: past})
      |> Repo.update()

    updated
  end

  @doc """
  Runs `fun` with `:revenuecat_access_enforcement` set to `true` and
  restores the previous value afterwards, even when `fun` raises.
  Used by Phase 4 channel tests to flip the shared rollout flag.
  """
  @spec with_enforcement_enabled!((-> any())) :: any()
  def with_enforcement_enabled!(fun) when is_function(fun, 0) do
    previous = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)
    Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, true)

    try do
      fun.()
    after
      Application.put_env(
        :meal_planner_api,
        :revenuecat_access_enforcement,
        previous
      )
    end
  end

  @doc """
  Runs `fun` with `:revenuecat_access_enforcement` explicitly set to
  `false` and restores the previous value afterwards. Used by the
  rollout-safety test that proves an expired Account can still join a
  product channel when the rollout flag is off.
  """
  @spec with_enforcement_disabled!((-> any())) :: any()
  def with_enforcement_disabled!(fun) when is_function(fun, 0) do
    previous = Application.get_env(:meal_planner_api, :revenuecat_access_enforcement)
    Application.put_env(:meal_planner_api, :revenuecat_access_enforcement, false)

    try do
      fun.()
    after
      Application.put_env(
        :meal_planner_api,
        :revenuecat_access_enforcement,
        previous
      )
    end
  end
end
