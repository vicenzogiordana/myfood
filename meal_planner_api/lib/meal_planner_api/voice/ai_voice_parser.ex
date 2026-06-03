defmodule MealPlannerApi.Voice.AIVoiceParser do
  @moduledoc """
  AI-backed voice parser using `AIPort`.

  Sends a structured prompt to the AI with inventory item names and expects
  a parsed result back. Falls back to `RuleBasedVoiceParser` on AI error.
  """

  @behaviour MealPlannerApi.Voice.VoiceParserPort

  @ai_parser_system_prompt """
  You are a kitchen inventory parser. Given a natural-language command and a list
  of inventory items, respond ONLY with a JSON array of quantity operations.
  Each operation: {"inventory_item_id": "<id>", "quantity_milli": <new_quantity_milli>}.
  The quantity is always in milliliters (or grams as milli-grams).
  If no items are mentioned, return [].
  """

  @impl true
  def parse(text, items) do
    ai_impl = Application.get_env(:meal_planner_api, :ai_port, MealPlannerApi.AI.GeminiAdapter)

    prompt = build_prompt(text, items)

    case ai_impl.generate_text(prompt, system_prompt: @ai_parser_system_prompt) do
      {:ok, json_string} ->
        parse_ai_response(json_string, text, items)

      {:error, _reason} ->
        MealPlannerApi.Voice.RuleBasedVoiceParser.parse(text, items)
    end
  end

  # ---

  defp build_prompt(text, items) do
    items_text =
      items
      |> Enum.map(fn %{id: id, name: name, quantity_milli: qty} ->
        "  - id: #{id}, name: #{name}, current qty: #{qty}ml"
      end)
      |> Enum.join("\n")

    """
    User said: "#{text}"

    Inventory items:
    #{items_text}

    Respond with JSON array only. Example: [{"inventory_item_id": "abc", "quantity_milli": 500}]
    """
  end

  defp parse_ai_response(json_string, text, items) do
    cleaned =
      json_string
      |> String.trim()
      |> String.replace_prefix("```json", "")
      |> String.replace_prefix("```", "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, ops} when is_list(ops) ->
        {:ok, ops}

      {:ok, _other} ->
        MealPlannerApi.Voice.RuleBasedVoiceParser.parse(text, items)

      {:error, _parse_error} ->
        MealPlannerApi.Voice.RuleBasedVoiceParser.parse(text, items)
    end
  end
end
