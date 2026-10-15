defmodule MealPlannerApi.PlanningAgent.SpendLedger do
  @moduledoc """
  Paid-service spend and cumulative token accounting for one Planning
  Session (spec #93, user stories 102 and 103). Separate from the grocery
  budget.

  The caps bound every OpenAI call of the whole Planning Session: the ledger
  is created when the session starts and is never reset between Member
  messages, so a second request spends from what the first one left. A new
  Planning Session starts with a fresh ledger (product decision, 2026-10-15).

  Before every paid call the worst-case cost and tokens are reserved; a call
  whose reservation would exceed either cap is refused before it is made.
  After the call the reservation is settled to the actual usage. When the
  actual usage is unknown (a failed call), the worst case stays spent.

  Amounts are integer micro-USD.
  """

  @enforce_keys [:spend_cap_micros, :token_cap]
  defstruct spend_cap_micros: nil,
            token_cap: nil,
            spent_micros: 0,
            spent_tokens: 0,
            reserved_micros: 0,
            reserved_tokens: 0

  @type t :: %__MODULE__{
          spend_cap_micros: pos_integer(),
          token_cap: pos_integer(),
          spent_micros: non_neg_integer(),
          spent_tokens: non_neg_integer(),
          reserved_micros: non_neg_integer(),
          reserved_tokens: non_neg_integer()
        }

  @type amount :: %{micros: non_neg_integer(), tokens: non_neg_integer()}

  @doc "Builds a ledger. Both caps are mandatory positive integers."
  @spec new(term(), term()) :: {:ok, t()} | {:error, :spend_caps_unconfigured}
  def new(spend_cap_micros, token_cap)
      when is_integer(spend_cap_micros) and spend_cap_micros > 0 and is_integer(token_cap) and
             token_cap > 0,
      do: {:ok, %__MODULE__{spend_cap_micros: spend_cap_micros, token_cap: token_cap}}

  def new(_spend_cap_micros, _token_cap), do: {:error, :spend_caps_unconfigured}

  @doc "Reserves a worst-case amount, or refuses when a cap would be exceeded."
  @spec reserve(t(), amount()) :: {:ok, t()} | {:error, :spend_cap_reached | :token_cap_reached}
  def reserve(%__MODULE__{} = ledger, %{micros: micros, tokens: tokens}) do
    cond do
      ledger.spent_micros + ledger.reserved_micros + micros > ledger.spend_cap_micros ->
        {:error, :spend_cap_reached}

      ledger.spent_tokens + ledger.reserved_tokens + tokens > ledger.token_cap ->
        {:error, :token_cap_reached}

      true ->
        {:ok,
         %{
           ledger
           | reserved_micros: ledger.reserved_micros + micros,
             reserved_tokens: ledger.reserved_tokens + tokens
         }}
    end
  end

  @doc "Releases `reservation` and records `actual` as spent."
  @spec settle(t(), amount(), amount()) :: t()
  def settle(%__MODULE__{} = ledger, reservation, actual) do
    %{
      ledger
      | reserved_micros: max(ledger.reserved_micros - reservation.micros, 0),
        reserved_tokens: max(ledger.reserved_tokens - reservation.tokens, 0),
        spent_micros: ledger.spent_micros + actual.micros,
        spent_tokens: ledger.spent_tokens + actual.tokens
    }
  end

  @doc "Spend summary."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = ledger),
    do: Map.take(ledger, [:spent_micros, :spent_tokens, :reserved_micros, :reserved_tokens])
end
