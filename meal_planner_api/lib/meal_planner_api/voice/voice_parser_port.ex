defmodule MealPlannerApi.Voice.VoiceParserPort do
  @moduledoc """
  Behaviour for voice-to-inventory-operation parsing.

  Used to interpret natural language inventory updates like
  "usé mitad de las verduras" into structured quantity operations.
  """

  @type inventory_item :: %{
          id: String.t(),
          name: String.t(),
          quantity_milli: integer()
        }

  @type parsed_operation :: %{
          inventory_item_id: String.t(),
          quantity_milli: integer()
        }

  @doc """
  Parses `text` (natural language) against the list of inventory `items`.

  Returns a list of parsed operations mapping item IDs to new quantities.
  """
  @callback parse(text :: String.t(), items :: [inventory_item()]) ::
              {:ok, [parsed_operation()]} | {:error, term()}
end
