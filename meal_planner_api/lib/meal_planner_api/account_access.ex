defmodule MealPlannerApi.AccountAccess do
  @moduledoc """
  Single Account-wide eligibility / status predicate.

  Every transport (HTTP plug, channel join, recovery route, status
  endpoint) calls into this module. JWT claims and RevenueCat
  `CustomerInfo` are NEVER consulted — only server-side persisted state.

  ## Boundary semantics (half-open intervals)

    * trial:       `trial_started_at <= now < trial_ends_at` is eligible.
    * entitlement: `is_active == true` AND
                   (`expiration_date > now` OR `grace_period_expires_date > now`).
                   Both nil = lifetime grant.

  Eligibility = "trial covers now" OR "any entitlement covers now".

  ## Purity

  `eligible?/2` and `status/2` are pure over an already-loaded Account
  struct (with `revenuecat_entitlements` preloaded). The DB-preloading
  `eligible?/1` overloads exist for one-shot callers.
  """

  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.RevenuecatEntitlement
  alias MealPlannerApi.Repo

  # Half-open: trial_ends_at is EXCLUSIVE. Mirrors the boundary cases in
  # `test/meal_planner_api/account_access_test.exs`.
  @trial_length_seconds 7 * 86_400

  @type state :: :trial | :active | :expired
  @type source :: :trial | :entitlement | :none

  defmodule Status do
    @moduledoc false
    defstruct state: :expired,
              source: :none,
              trial_started_at: nil,
              trial_ends_at: nil,
              latest_provider_event_at: nil

    @type state :: :trial | :active | :expired
    @type source :: :trial | :entitlement | :none

    @type t :: %__MODULE__{
            state: state(),
            source: source(),
            trial_started_at: DateTime.t() | nil,
            trial_ends_at: DateTime.t() | nil,
            latest_provider_event_at: DateTime.t() | nil
          }
  end

  @doc """
  DB-preloading convenience overloads. Return `false` for `nil`/missing.
  """
  @spec eligible?(Account.t() | Ecto.UUID.t() | String.t() | nil) :: boolean()
  def eligible?(nil), do: false

  def eligible?(%Account{} = account), do: eligible?(account, DateTime.utc_now())

  def eligible?(account_id) when is_binary(account_id) do
    case load_account(account_id) do
      nil -> false
      account -> eligible?(account, DateTime.utc_now())
    end
  end

  @doc """
  Pure eligibility decision. Half-open: `now == trial_ends_at` is NOT
  eligible; `now == trial_started_at` IS eligible.
  """
  @spec eligible?(Account.t() | nil, DateTime.t()) :: boolean()
  def eligible?(nil, _now), do: false

  def eligible?(%Account{} = account, %DateTime{} = now) do
    trial_active?(account, now) or entitlement_active?(account, now)
  end

  @doc """
  Structured status payload for `/api/billing/revenuecat/status`.

  `state` precedence: `:trial` (window active) > `:active` (entitlement
  active) > `:expired`. `source` is `:trial | :entitlement | :none` based
  on which persisted fact produced the state.
  """
  @spec status(Account.t() | nil, DateTime.t()) :: Status.t()
  def status(nil, _now), do: %Status{}

  def status(%Account{} = account, %DateTime{} = now) do
    cond do
      trial_active?(account, now) ->
        build_status(account, :trial, :trial)

      entitlement_active?(account, now) ->
        build_status(account, :active, :entitlement)

      true ->
        build_status(account, :expired, source_when_inactive(account))
    end
  end

  @doc """
  7-day trial window for the first qualifying RevenueCat event (Phase 2
  / PR 2 wiring). Centralized here so every transport sees the same
  window length.
  """
  @spec trial_window(DateTime.t()) :: %{started_at: DateTime.t(), ends_at: DateTime.t()}
  def trial_window(started_at) do
    %{
      started_at: started_at,
      ends_at: DateTime.add(started_at, @trial_length_seconds, :second)
    }
  end

  # ---- trial predicate ------------------------------------------------------

  defp trial_active?(%Account{trial_started_at: nil}, _now), do: false
  defp trial_active?(%Account{trial_ends_at: nil}, _now), do: false

  defp trial_active?(%Account{} = account, %DateTime{} = now) do
    started = account.trial_started_at
    ended = account.trial_ends_at

    # Half-open: `started <= now` (`:lt` or `:eq`) AND `now < ended` (`:lt`).
    DateTime.compare(started, now) in [:lt, :eq] and DateTime.compare(now, ended) == :lt
  end

  defp trial_recorded?(%Account{trial_started_at: nil}), do: false
  defp trial_recorded?(%Account{trial_started_at: _}), do: true

  # ---- entitlement predicate ------------------------------------------------

  defp entitlement_active?(%Account{revenuecat_entitlements: entitlements}, %DateTime{} = now)
       when is_list(entitlements) do
    Enum.any?(entitlements, &entitlement_covers?(&1, now))
  end

  defp entitlement_active?(%Account{}, _now), do: false

  defp entitlement_covers?(%RevenuecatEntitlement{is_active: false}, _now), do: false

  defp entitlement_covers?(
         %RevenuecatEntitlement{is_active: true} = entitlement,
         %DateTime{} = now
       ) do
    expiration = Map.get(entitlement, :expiration_date)
    grace = Map.get(entitlement, :grace_period_expires_date)

    case {expiration, grace} do
      # Lifetime grant — no expiration recorded on either side.
      {nil, nil} ->
        true

      {%DateTime{} = e, %DateTime{} = g} ->
        DateTime.compare(e, now) == :gt or DateTime.compare(g, now) == :gt

      {%DateTime{} = e, nil} ->
        DateTime.compare(e, now) == :gt

      {nil, %DateTime{} = g} ->
        DateTime.compare(g, now) == :gt
    end
  end

  defp entitlement_covers?(_, _now), do: false

  # ---- status helpers -------------------------------------------------------

  defp build_status(account, state, source) do
    %Status{
      state: state,
      source: source,
      trial_started_at: account.trial_started_at,
      trial_ends_at: account.trial_ends_at,
      latest_provider_event_at: account.latest_provider_event_at
    }
  end

  defp source_when_inactive(%Account{} = account) do
    cond do
      trial_recorded?(account) -> :trial
      has_any_entitlements?(account) -> :entitlement
      true -> :none
    end
  end

  defp has_any_entitlements?(%Account{revenuecat_entitlements: entitlements})
       when is_list(entitlements),
       do: entitlements != []

  defp has_any_entitlements?(%Account{}), do: false

  # ---- DB helper ------------------------------------------------------------

  defp load_account(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, uuid} ->
        Account
        |> Repo.get(uuid)
        |> Repo.preload(:revenuecat_entitlements)

      _ ->
        nil
    end
  end
end
