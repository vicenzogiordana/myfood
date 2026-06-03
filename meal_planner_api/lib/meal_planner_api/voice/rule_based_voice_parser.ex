defmodule MealPlannerApi.Voice.RuleBasedVoiceParser do
  @moduledoc """
  Pure Elixir voice parser. No AI needed.

  Patterns:
  - "mitad del kilo de <name>" → 500ml (500 grams → assumed for dry goods)
  - "mitad" / "medio" <name> → half current quantity
  - "<name>" mentioned somewhere → quarter current quantity
  - "terminé de usar" / "terminé" <name> → set to 0
  """

  @behaviour MealPlannerApi.Voice.VoiceParserPort

  @impl true
  def parse(text, items) when is_binary(text) and is_list(items) do
    lowered = String.downcase(text)

    operations =
      items
      |> Enum.map(&parse_item(&1, lowered))
      |> Enum.reject(&is_nil/1)

    {:ok, operations}
  end

  # ---

  defp parse_item(%{id: id, name: name, quantity_milli: current_qty}, text) do
    name_lowered = String.downcase(name)

    cond do
      # "mitad del kilo de [name]" → 500ml (predefined amount)
      String.contains?(text, "mitad del kilo") && String.contains?(text, name_lowered) ->
        %{inventory_item_id: id, quantity_milli: 500_000}

      # "terminé" / "terminé de usar" [name] → 0
      (String.contains?(text, "termin") || String.contains?(text, "terminé")) &&
          String.contains?(text, name_lowered) ->
        %{inventory_item_id: id, quantity_milli: 0}

      # "mitad" [name] → half current
      String.contains?(text, "mitad") && String.contains?(text, name_lowered) ->
        %{inventory_item_id: id, quantity_milli: div(current_qty, 2)}

      # "medio" [name] → half current
      String.contains?(text, "medio") && String.contains?(text, name_lowered) ->
        %{inventory_item_id: id, quantity_milli: div(current_qty, 2)}

      # [name] mentioned anywhere → quarter current
      String.contains?(text, name_lowered) ->
        %{inventory_item_id: id, quantity_milli: max(div(current_qty, 4), 1)}

      true ->
        nil
    end
  end
end
