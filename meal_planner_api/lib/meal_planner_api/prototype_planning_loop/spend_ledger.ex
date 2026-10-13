# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule MealPlannerApi.PrototypePlanningLoop.SpendLedger do
  @moduledoc """
  Accumulates API-reported usage across all runs in a local throwaway JSON
  file next to this module, and enforces the spend ceiling.
  """

  @file_name "PROTOTYPE_WIPE_ME_spend_ledger.json"
  @hard_cap_usd 5.0

  # USD per 1M tokens.
  @input_usd 2.0
  @cached_input_usd 0.10
  @output_usd 10.0

  def path, do: Path.join(__DIR__, @file_name)

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
    empty = %{
      "calls" => 0,
      "input_tokens" => 0,
      "cached_input_tokens" => 0,
      "output_tokens" => 0,
      "usd" => 0.0
    }

    with {:ok, body} <- File.read(path()),
         {:ok, %{} = ledger} <- Jason.decode(body) do
      Map.merge(empty, ledger)
    else
      {:error, :enoent} ->
        empty

      # An unreadable ledger must not look like zero spend.
      other ->
        raise "spend ledger at #{path()} is unreadable (#{inspect(other)}); fix or delete it by hand"
    end
  end

  @doc """
  `:ok` when a call whose worst case costs `worst_case_usd` still fits under
  the ceiling, otherwise `{:error, message}`. Being at or over the ceiling
  always refuses.
  """
  def check(worst_case_usd) do
    spent = read()["usd"]
    cap = cap_usd()

    cond do
      spent >= cap ->
        {:error,
         "spend ceiling reached: USD #{fmt(spent)} spent of USD #{fmt(cap)}; no further model calls"}

      spent + worst_case_usd > cap ->
        {:error,
         "spend ceiling would be exceeded: USD #{fmt(spent)} spent, next call could cost up to USD #{fmt(worst_case_usd)}, ceiling USD #{fmt(cap)}; no further model calls"}

      true ->
        :ok
    end
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

  @doc "Adds one call's usage to the file and returns the spend summary."
  def record(usage) do
    ledger = read()

    updated = %{
      "calls" => ledger["calls"] + 1,
      "input_tokens" => ledger["input_tokens"] + usage.input_tokens,
      "cached_input_tokens" => ledger["cached_input_tokens"] + usage.cached_input_tokens,
      "output_tokens" => ledger["output_tokens"] + usage.output_tokens,
      "usd" => ledger["usd"] + cost_usd(usage)
    }

    File.write!(path(), Jason.encode!(updated, pretty: true))

    %{
      call_usd: cost_usd(usage),
      total_usd: updated["usd"],
      cap_usd: cap_usd(),
      calls: updated["calls"]
    }
  end

  def fmt(usd), do: :erlang.float_to_binary(usd * 1.0, decimals: 4)
end
