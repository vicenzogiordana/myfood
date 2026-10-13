# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule MealPlannerApi.PrototypePlanningLoop.SpendLedger do
  @moduledoc """
  Accumulates API spend across all runs in a local throwaway JSON file next to
  this module, and enforces the spend ceiling.

  The ledger may over-count but never under-count. Before a live call its
  worst-case cost is written as a reservation (`reserve/1`); after a complete
  response the reservation is replaced by the cost of the reported usage
  (`settle/2`). A call that is killed, times out or dies with its process never
  settles, so its reservation stays in the file and counts as spent, in this
  run and in every later one.
  """

  @file_name "PROTOTYPE_WIPE_ME_spend_ledger.json"
  @hard_cap_usd 5.0

  # USD per 1M tokens.
  @input_usd 2.0
  @cached_input_usd 0.10
  @output_usd 10.0

  @empty %{
    "calls" => 0,
    "input_tokens" => 0,
    "cached_input_tokens" => 0,
    "output_tokens" => 0,
    "usd" => 0.0,
    "reserved_usd" => 0.0
  }

  @doc "Ledger file. `PROTOTYPE_SPEND_LEDGER_PATH` points it elsewhere for offline checks."
  def path, do: System.get_env("PROTOTYPE_SPEND_LEDGER_PATH") || Path.join(__DIR__, @file_name)

  @doc "Ceiling in USD. `PROTOTYPE_SPEND_CAP_USD` may only lower it."
  def cap_usd do
    with value when is_binary(value) <- System.get_env("PROTOTYPE_SPEND_CAP_USD"),
         {cap, ""} when cap >= 0 <- Float.parse(value) do
      min(cap, @hard_cap_usd)
    else
      _ -> @hard_cap_usd
    end
  end

  def read do
    with {:ok, body} <- File.read(path()),
         {:ok, %{} = ledger} <- Jason.decode(body) do
      Map.merge(@empty, ledger)
    else
      {:error, :enoent} ->
        @empty

      # An unreadable ledger must not look like zero spend.
      other ->
        raise "spend ledger at #{path()} is unreadable (#{inspect(other)}); fix or delete it by hand"
    end
  end

  @doc "Spend that counts against the ceiling: settled cost plus open reservations."
  def spent_usd(ledger \\ read()), do: ledger["usd"] + ledger["reserved_usd"]

  @doc """
  Reserves `worst_case_usd` for one call and persists it before the call is
  made. Refuses with `{:error, message}` when spend is at or over the ceiling,
  or when this call's worst case would cross it.
  """
  def reserve(worst_case_usd) do
    ledger = read()
    spent = spent_usd(ledger)
    cap = cap_usd()

    cond do
      spent >= cap ->
        {:error,
         "spend ceiling reached: USD #{fmt(spent)} spent of USD #{fmt(cap)}#{unreconciled_note(ledger)}; no further model calls"}

      spent + worst_case_usd > cap ->
        {:error,
         "spend ceiling would be exceeded: USD #{fmt(spent)} spent#{unreconciled_note(ledger)}, next call could cost up to USD #{fmt(worst_case_usd)}, ceiling USD #{fmt(cap)}; no further model calls"}

      true ->
        write(%{ledger | "reserved_usd" => ledger["reserved_usd"] + worst_case_usd})
        :ok
    end
  end

  @doc """
  Replaces a reservation with the actual cost of `usage` and returns the spend
  summary. Only called after a complete response with reported usage.
  """
  def settle(worst_case_usd, usage) do
    ledger = read()

    summary(
      write(%{
        "calls" => ledger["calls"] + 1,
        "input_tokens" => ledger["input_tokens"] + usage.input_tokens,
        "cached_input_tokens" => ledger["cached_input_tokens"] + usage.cached_input_tokens,
        "output_tokens" => ledger["output_tokens"] + usage.output_tokens,
        "usd" => ledger["usd"] + cost_usd(usage),
        "reserved_usd" => max(ledger["reserved_usd"] - worst_case_usd, 0.0)
      }),
      cost_usd(usage)
    )
  end

  @doc """
  Drops a reservation without recording cost. Only for a call the provider
  provably did not process (it answered with a 4xx rejection).
  """
  def release(worst_case_usd) do
    ledger = read()
    write(%{ledger | "reserved_usd" => max(ledger["reserved_usd"] - worst_case_usd, 0.0)})
    :ok
  end

  def summary(ledger \\ read(), call_usd \\ 0.0) do
    %{
      call_usd: call_usd,
      total_usd: spent_usd(ledger),
      reserved_usd: ledger["reserved_usd"],
      cap_usd: cap_usd(),
      calls: ledger["calls"]
    }
  end

  def cost_usd(usage) do
    uncached = max(usage.input_tokens - usage.cached_input_tokens, 0)

    (uncached * @input_usd + usage.cached_input_tokens * @cached_input_usd +
       usage.output_tokens * @output_usd) /
      1_000_000
  end

  def worst_case_usd(input_tokens, max_output_tokens) do
    (input_tokens * @input_usd + max_output_tokens * @output_usd) / 1_000_000
  end

  def fmt(usd), do: :erlang.float_to_binary(usd * 1.0, decimals: 4)

  defp unreconciled_note(%{"reserved_usd" => reserved}) when reserved > 0 do
    " (including USD #{fmt(reserved)} of unreconciled reservations)"
  end

  defp unreconciled_note(_ledger), do: ""

  defp write(ledger) do
    File.write!(path(), Jason.encode!(ledger, pretty: true))
    ledger
  end
end
