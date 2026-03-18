defmodule MealPlannerApi.Messages do
  @moduledoc """
  Message context for AI conversation history and system persona.
  """

  alias MealPlannerApi.Messages.Message

  @persona "You are MyFood's Personal Economist Chef: friendly, professional, warm, and highly efficient. Prioritize savings, reduced cooking time, and zero food waste."

  @spec persona() :: String.t()
  def persona, do: @persona

  @spec parse_history(map()) :: [Message.t()]
  def parse_history(params) do
    messages =
      case Map.get(params, "messages", []) do
        list when is_list(list) -> list
        _ -> []
      end

    messages
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn msg ->
      %Message{
        role: normalize_role(Map.get(msg, "role", "user")),
        content: Map.get(msg, "content", "")
      }
    end)
  end

  defp normalize_role("assistant"), do: :assistant
  defp normalize_role("system"), do: :system
  defp normalize_role(_), do: :user
end
