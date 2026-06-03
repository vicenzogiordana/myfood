defmodule MealPlannerApi.Integrations.GoScraperClient.Mock do
  @moduledoc """
  Deterministic mock for the Go scraper API in dev and test.

  Returns realistic product data without hitting any external service.
  """

  @supermarkets ~w(jumbo carrefour dia disco vea masonline farmacity)

  @doc "Fetches mock product data for any ingredient name."
  @spec fetch(String.t()) :: {:ok, map()}
  def fetch(ingredient_name) when is_binary(ingredient_name) do
    products = build_mock_products(ingredient_name)
    failed_scrapers = failed_scrapers_for_name(ingredient_name)

    {:ok, %{products: products, failed_scrapers: failed_scrapers}}
  end

  @spec unit_price_to_cents(float()) :: non_neg_integer()
  def unit_price_to_cents(unit_price), do: round(unit_price * 100)

  def base_url, do: "http://mock-scraper:3000"

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp build_mock_products(ingredient_name) do
    base_prices = base_prices_for_ingredient(ingredient_name)
    unit = unit_for_ingredient(ingredient_name)

    @supermarkets
    |> Enum.take(4)
    |> Enum.with_index()
    |> Enum.map(fn {source, idx} ->
      %{
        source: source,
        name:
          "#{String.capitalize(ingredient_name)} #{pack_descriptions() |> Enum.at(idx, "premium")}",
        price: Enum.fetch!(base_prices, idx) * 1.0,
        unit_price: Enum.fetch!(base_prices, idx),
        unit: unit,
        unavailable: idx == 2
      }
    end)
  end

  defp base_prices_for_ingredient(name) do
    hash = :erlang.phash2(name)

    prices =
      case name do
        n when n in ~w(pollo chicken carne) -> [14.5, 15.0, 14.0, 15.5]
        n when n in ~w(huevo huevos) -> [0.80, 0.75, 0.90, 0.85]
        n when n in ~w(leche leche_entera) -> [1.2, 1.3, 1.1, 1.25]
        n when n in ~w(arroz) -> [2.5, 2.8, 2.3, 2.6]
        n when n in ~w(tomate tomates) -> [3.5, 3.8, 4.0, 3.6]
        _ -> [5.0, 5.5, 4.8, 5.2]
      end

    seed = hash |> Integer.mod(100) |> Kernel./(100)
    Enum.map(prices, &Float.round(&1 + seed, 2))
  end

  defp unit_for_ingredient(name) do
    case name do
      n when n in ~w(leche) -> "l"
      n when n in ~w(huevo huevos) -> "unit"
      _ -> "kg"
    end
  end

  defp pack_descriptions, do: ["500g", "1kg", "pack 3u", "premium 1kg"]

  defp failed_scrapers_for_name(name) do
    case :erlang.phash2(name) |> rem(5) do
      0 -> ["carrefour"]
      1 -> ["coto"]
      2 -> []
      _ -> []
    end
  end
end
