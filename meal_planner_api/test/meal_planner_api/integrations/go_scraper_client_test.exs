defmodule MealPlannerApi.Integrations.GoScraperClientTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Integrations.GoScraperClient

  describe "fetch/1" do
    test "has correct arity" do
      assert is_function(&GoScraperClient.fetch/1, 1)
    end

    test "accepts a string ingredient name" do
      result = GoScraperClient.fetch("pollo")
      assert is_tuple(result)
    end
  end

  describe "unit_price_to_cents/1" do
    test "converts float price to cents (integer)" do
      assert GoScraperClient.unit_price_to_cents(15.99) == 1599
    end

    test "rounds to nearest cent" do
      assert GoScraperClient.unit_price_to_cents(15.995) == 1600
    end

    test "handles zero" do
      assert GoScraperClient.unit_price_to_cents(0.0) == 0
    end
  end

  describe "base_url/0" do
    test "returns a string URL" do
      url = GoScraperClient.base_url()
      assert is_binary(url)
      assert url =~ "http"
    end
  end
end
