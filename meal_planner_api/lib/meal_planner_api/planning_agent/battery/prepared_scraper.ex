defmodule MealPlannerApi.PlanningAgent.Battery.PreparedScraper do
  @moduledoc """
  Price scraper of the quality battery (issue #109): it answers prepared
  responses and never reaches the internet, so every run sees identical
  live prices (#87, privacy-safe fixtures).

  Options: `:responses` maps a lowercased query to `{:ok, items}` or
  `{:error, reason}`; `:default` answers every other query (default: no
  live offers, `{:ok, []}`).
  """

  @behaviour MealPlannerApi.PlanningAgent.PriceScraper

  @impl true
  def fetch(query, opts) do
    opts
    |> Keyword.get(:responses, %{})
    |> Map.get(String.downcase(query), Keyword.get(opts, :default, {:ok, []}))
  end
end
