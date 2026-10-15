defmodule MealPlannerApi.PlanningAgent.PriceScraper.HttpTest do
  @moduledoc """
  The HTTP scraper adapter against the price contract of
  `docs/price-scraper-contract.md` (issue #101), with a `Req.Test` stub and
  fictitious products.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.PriceScraper.Http

  @stub __MODULE__

  defp fetch(query \\ "Fictitious Pasta"),
    do: Http.fetch(query, base_url: "http://scraper.test", req_options: [plug: {Req.Test, @stub}])

  defp stub_products(products) do
    Req.Test.stub(@stub, fn conn ->
      send(self(), {:query, conn.query_string})
      Req.Test.json(conn, %{"products" => products, "failedScrapers" => []})
    end)
  end

  defp product(attrs) do
    Map.merge(
      %{
        "source" => "fictitious-market",
        "name" => "Fictitious spaghetti 500 g",
        "brand" => "Fictitious Brand",
        "price" => 1250.5,
        "currency" => "ARS",
        "packageQuantity" => 500,
        "packageUnit" => "g",
        "observedAt" => "2026-11-01T09:00:00Z",
        "cached" => true,
        "unavailable" => false
      },
      attrs
    )
  end

  test "parses a full contract product into a scraped price item" do
    stub_products([product(%{})])

    assert {:ok,
            [
              %{
                supermarket: "fictitious-market",
                product: "Fictitious spaghetti 500 g",
                brand: "Fictitious Brand",
                package_quantity_milli: 500_000,
                package_unit: :g,
                price_cents: 125_050,
                currency: "ARS",
                observed_at: ~U[2026-11-01 09:00:00Z],
                cached?: true
              }
            ]} = fetch()
  end

  test "queries the scraper with the lowercased name" do
    stub_products([])

    assert {:ok, []} = fetch("Fictitious Pasta")
    assert_received {:query, "q=fictitious+pasta"}
  end

  test "converts kilograms and litres to milli grams and millilitres" do
    stub_products([
      product(%{"packageQuantity" => 1.5, "packageUnit" => "kg"}),
      product(%{"name" => "Fictitious oil", "packageQuantity" => 1, "packageUnit" => "l"}),
      product(%{"name" => "Fictitious eggs", "packageQuantity" => 12, "packageUnit" => "unit"})
    ])

    assert {:ok, items} = fetch()

    assert Enum.map(items, &{&1.package_quantity_milli, &1.package_unit}) ==
             [{1_500_000, :g}, {1_000_000, :ml}, {12_000, :unit}]
  end

  test "drops products missing observation time, cache flag, currency or package size" do
    stub_products([
      Map.delete(product(%{}), "observedAt"),
      Map.delete(product(%{}), "cached"),
      Map.delete(product(%{}), "currency"),
      Map.delete(product(%{}), "packageQuantity"),
      product(%{"packageUnit" => "bunch"}),
      product(%{"observedAt" => "yesterday"}),
      product(%{"unavailable" => true})
    ])

    assert {:ok, []} = fetch()
  end

  test "a product without a brand keeps a nil brand" do
    stub_products([Map.delete(product(%{}), "brand")])

    assert {:ok, [%{brand: nil}]} = fetch()
  end

  test "a server error is unreachable and a malformed body is invalid" do
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
    assert {:error, :scraper_unreachable} = fetch()

    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)
    assert {:error, :invalid_scraper_response} = fetch()
  end
end
