defmodule MealPlannerApi.Planning.RecipeOrigin do
  @moduledoc """
  Recipe Origin as shown to Members (see `CONTEXT.md`): whether a recipe is
  traditional, AI-created or user-created. It is stored as the recipe's
  `source`; this module is the one mapping between both.
  """

  @labels %{traditional: "traditional", ai_generated: "ai_created", user_created: "user_created"}

  @doc "The Recipe Origin label of a stored recipe `source`."
  @spec label(:traditional | :ai_generated | :user_created | nil) :: String.t()
  def label(source) when is_map_key(@labels, source), do: Map.fetch!(@labels, source)
  # A recipe without a recorded source predates Recipe Origin: the catalog.
  def label(nil), do: "traditional"

  @doc "The stored `source` of a Recipe Origin label a Draft may carry."
  @spec draft_source(String.t()) :: {:ok, :ai_generated | :user_created} | :error
  def draft_source("ai_created"), do: {:ok, :ai_generated}
  def draft_source("user_created"), do: {:ok, :user_created}
  def draft_source(_label), do: :error
end
