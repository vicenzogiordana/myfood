defmodule MealPlannerApi.PlanningAgent.PriceScraper.Unavailable do
  @moduledoc """
  Price scraper used when none is configured (the test default): every live
  lookup fails with `:scraper_unavailable`, so stored prices are kept with
  their real age and missing prices stay missing.
  """

  @behaviour MealPlannerApi.PlanningAgent.PriceScraper

  @impl true
  def fetch(_query, _opts), do: {:error, :scraper_unavailable}
end
