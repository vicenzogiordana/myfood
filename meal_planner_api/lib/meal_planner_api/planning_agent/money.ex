defmodule MealPlannerApi.PlanningAgent.Money do
  @moduledoc """
  Code-formatted money for the model (issue #160). Tool results carry money
  as integer cents (`*_cents`); a model read them as pesos and quoted a plan
  100 times too expensive. Every model-facing tool result is annotated with
  the human amount next to each integer `*_cents` field, formatted by code
  (`"purchase_total": "ARS 49.950,00"` beside `"purchase_total_cents"`), and
  the instructions tell the model to quote only those.

  The format is the household's: currency code, `.` between thousands and
  `,` before the two decimals.
  """

  alias MealPlannerApi.PlanningAgent.Purchase

  @suffix "_cents"

  @doc "`cents` as a human amount of `currency` (default: the budget currency)."
  @spec format(integer(), String.t()) :: String.t()
  def format(cents, currency \\ Purchase.currency()) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    units = cents |> abs() |> div(100)
    decimals = cents |> abs() |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{currency} #{sign}#{thousands(units)},#{decimals}"
  end

  @doc """
  `content` with a formatted amount beside every integer `*_cents` field,
  nested maps and lists included. The amount takes the field name without
  `_cents` (`<name>_formatted` when that name is taken) and the currency of
  the same map's `"currency"`, else the budget currency.
  """
  @spec annotate(term()) :: term()
  def annotate(content) when is_map(content) and not is_struct(content) do
    currency =
      case Map.get(content, "currency") do
        currency when is_binary(currency) -> currency
        _ -> Purchase.currency()
      end

    annotated = Map.new(content, fn {key, value} -> {key, annotate(value)} end)

    Enum.reduce(content, annotated, fn
      {key, cents}, acc when is_binary(key) and is_integer(cents) ->
        if String.ends_with?(key, @suffix),
          do: Map.put(acc, amount_key(key, content), format(cents, currency)),
          else: acc

      _field, acc ->
        acc
    end)
  end

  def annotate(content) when is_list(content), do: Enum.map(content, &annotate/1)
  def annotate(content), do: content

  defp amount_key(key, content) do
    base = String.replace_suffix(key, @suffix, "")
    if Map.has_key?(content, base), do: base <> "_formatted", else: base
  end

  defp thousands(units) do
    units
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(".", &Enum.join/1)
    |> String.reverse()
  end
end
