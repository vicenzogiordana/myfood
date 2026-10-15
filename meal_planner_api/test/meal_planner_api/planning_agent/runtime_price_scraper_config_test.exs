defmodule MealPlannerApi.PlanningAgent.RuntimePriceScraperConfigTest do
  @moduledoc """
  The production price scraper comes from `GO_SCRAPER_URL` in
  config/runtime.exs (issue #101): without it the planning agent uses the
  `Unavailable` scraper instead of silently calling localhost.
  """

  # Reads and changes OS environment variables.
  use ExUnit.Case, async: false

  alias MealPlannerApi.PlanningAgent.PriceScraper

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @vars ~w(GO_SCRAPER_URL GUARDIAN_SECRET_KEY SECRET_KEY_BASE AI_CLIENT)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("GUARDIAN_SECRET_KEY", "fictitious-guardian-secret")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    System.delete_env("AI_CLIENT")
    :ok
  end

  defp prod_price_scraper do
    @runtime
    |> Config.Reader.read!(env: :prod, target: :host)
    |> get_in([:meal_planner_api, :planning_agent, :price_scraper])
  end

  test "without GO_SCRAPER_URL production uses the Unavailable scraper" do
    System.delete_env("GO_SCRAPER_URL")
    assert prod_price_scraper() == {PriceScraper.Unavailable, []}

    System.put_env("GO_SCRAPER_URL", "  ")
    assert prod_price_scraper() == {PriceScraper.Unavailable, []}
  end

  test "with GO_SCRAPER_URL production calls that URL over HTTP" do
    System.put_env("GO_SCRAPER_URL", "https://scraper.example.test")

    assert prod_price_scraper() ==
             {PriceScraper.Http, [base_url: "https://scraper.example.test"]}
  end
end
