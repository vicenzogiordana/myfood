defmodule MealPlannerApi.PlanningAgent.Model.PaidCall do
  @moduledoc """
  What every paid model adapter of the planning agent shares (spec #93):
  the global provider concurrency cap, the HTTP failure classification,
  the reserved-state checkpoint, the mandatory-configuration checks and the
  spend kept across a server restart.

  Provider failures are typed: `:provider_unauthorized` (401/403),
  `:provider_rejected_request` (other 4xx), `:provider_conflict` (409),
  `:provider_timeout` (transport timeout) and `:provider_unavailable`
  (408, 429, 5xx, other transport errors). Only the last two are transient
  (see `MealPlannerApi.PlanningAgent.CallBounds`).
  """

  alias MealPlannerApi.PlanningAgent.{ConcurrencyLimiter, SpendLedger}

  @doc """
  Runs `paid_call` (which returns the adapter's `respond/2` result) inside
  the global provider concurrency cap. A call over the cap is refused with
  `:provider_busy` before any spend is reserved.
  """
  @spec limited(map(), term(), (-> tuple())) :: tuple()
  def limited(%{concurrency_limiter: limiter, max_concurrent_calls: cap}, state, paid_call) do
    case ConcurrencyLimiter.run(limiter, :provider_calls, cap, paid_call) do
      {:ok, result} -> result
      {:error, :at_capacity} -> {:error, :provider_busy, state}
      {:error, :unconfigured} -> {:error, :spend_caps_unconfigured, state}
    end
  end

  @doc "POSTs with `Req` (never retried here) and classifies the outcome."
  @spec post(keyword()) :: {:ok, map()} | {:error, atom()}
  def post(options) do
    options
    |> Keyword.put(:retry, false)
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{} = response}} ->
        {:ok, response}

      {:ok, %Req.Response{status: status}} ->
        {:error, status_reason(status)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :provider_timeout}

      {:error, _exception} ->
        {:error, :provider_unavailable}
    end
  end

  # Permission, invalid request and conflict answers are never retried
  # automatically.
  defp status_reason(status) when status in [401, 403], do: :provider_unauthorized
  defp status_reason(409), do: :provider_conflict
  defp status_reason(status) when status in [408, 429], do: :provider_unavailable
  defp status_reason(status) when status in 400..499, do: :provider_rejected_request
  defp status_reason(_status), do: :provider_unavailable

  @doc """
  Reports the reserved state through the request's optional `:checkpoint`
  callback, so a turn killed mid-call still counts the reservation.
  """
  @spec checkpoint(map(), term()) :: any()
  def checkpoint(%{checkpoint: checkpoint}, state) when is_function(checkpoint, 1),
    do: checkpoint.(state)

  def checkpoint(_request, _state), do: :ok

  @doc "The global concurrency cap is mandatory like the spend caps."
  @spec validate_concurrency(map()) :: :ok | {:error, :spend_caps_unconfigured}
  def validate_concurrency(config) do
    case config[:max_concurrent_calls] do
      cap when is_integer(cap) and cap > 0 -> :ok
      _ -> {:error, :spend_caps_unconfigured}
    end
  end

  @spec validate_api_key(map()) :: :ok | {:error, :provider_unconfigured}
  def validate_api_key(config) do
    case config[:api_key] do
      key when is_binary(key) and key != "" -> :ok
      _ -> {:error, :provider_unconfigured}
    end
  end

  @doc "Micro-USD for `tokens` at `price` micro-USD per million tokens, rounded up."
  @spec micros(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def micros(tokens, price), do: div(tokens * price + 999_999, 1_000_000)

  @spec non_neg_integer?(term()) :: boolean()
  def non_neg_integer?(value), do: is_integer(value) and value >= 0

  @doc """
  The spend kept across a server restart (issue #107). A reservation still
  open belongs to a call whose outcome is unknown, so its worst case is
  counted as spent.
  """
  @spec recoverable_spend(SpendLedger.t()) :: %{
          spent_micros: non_neg_integer(),
          spent_tokens: non_neg_integer()
        }
  def recoverable_spend(ledger) do
    %{
      spent_micros: ledger.spent_micros + ledger.reserved_micros,
      spent_tokens: ledger.spent_tokens + ledger.reserved_tokens
    }
  end

  @doc "A fresh ledger carrying the kept spend."
  @spec restore_spend(SpendLedger.t(), map()) :: SpendLedger.t()
  def restore_spend(ledger, %{spent_micros: micros, spent_tokens: tokens}),
    do: %{ledger | spent_micros: micros, spent_tokens: tokens}
end
