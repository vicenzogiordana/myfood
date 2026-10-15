defmodule MealPlannerApi.PlanningAgent.PriceScraper.Http do
  @moduledoc """
  HTTP adapter of `MealPlannerApi.PlanningAgent.PriceScraper` for the
  `ratoneando-go` scraper (`GET <base_url>/?q=<query>`).

  It expects the price contract of `docs/price-scraper-contract.md`: per
  product `source`, `name`, `brand`, `price` (per package, major units),
  `currency`, `packageQuantity`, `packageUnit` (`g`, `kg`, `ml`, `l` or
  `unit`), `observedAt` (ISO 8601) and `cached`. A product missing any
  required field, or marked `unavailable`, is dropped: an observation time,
  currency or package size is never assumed. Until the scraper exposes the
  contract, every product is dropped and prices stay missing or stale.

  Options: `:base_url` (default: the `:go_scraper_url` application env),
  `:receive_timeout` (default 15 s; the read-call deadline also applies) and
  `:req_options`, merged into the request (used by tests for a `Req.Test`
  plug).
  """

  @behaviour MealPlannerApi.PlanningAgent.PriceScraper

  @default_base_url "http://localhost:3000"
  @units %{"g" => {:g, 1}, "kg" => {:g, 1000}, "ml" => {:ml, 1}, "l" => {:ml, 1000}}

  @impl true
  def fetch(query, opts) do
    base_url =
      Keyword.get_lazy(opts, :base_url, fn ->
        Application.get_env(:meal_planner_api, :go_scraper_url, @default_base_url)
      end)

    request =
      Keyword.merge(
        [
          url: base_url,
          params: [q: String.downcase(query)],
          receive_timeout: Keyword.get(opts, :receive_timeout, 15_000),
          retry: false
        ],
        Keyword.get(opts, :req_options, [])
      )

    case Req.get(request) do
      {:ok, %{status: 200, body: %{"products" => products}}} when is_list(products) ->
        {:ok, Enum.flat_map(products, &item/1)}

      {:ok, %{status: 200}} ->
        {:error, :invalid_scraper_response}

      {:ok, %{status: _status}} ->
        {:error, :scraper_unreachable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :scraper_unreachable}
    end
  end

  defp item(%{"unavailable" => true}), do: []

  defp item(
         %{
           "source" => supermarket,
           "name" => product,
           "price" => price,
           "currency" => currency,
           "packageQuantity" => quantity,
           "packageUnit" => unit,
           "observedAt" => observed_at,
           "cached" => cached
         } = raw
       )
       when is_binary(supermarket) and supermarket != "" and is_binary(product) and
              product != "" and is_number(price) and price >= 0 and is_binary(currency) and
              is_number(quantity) and quantity > 0 and is_boolean(cached) do
    with {:ok, package_unit, quantity_milli} <- package(unit, quantity),
         true <- Regex.match?(~r/\A[A-Z]{3}\z/, currency),
         {:ok, observed_at, _offset} <- DateTime.from_iso8601(observed_at) do
      [
        %{
          supermarket: supermarket,
          product: product,
          brand: brand(raw["brand"]),
          package_quantity_milli: quantity_milli,
          package_unit: package_unit,
          price_cents: round(price * 100),
          currency: currency,
          observed_at: observed_at,
          cached?: cached
        }
      ]
    else
      _ -> []
    end
  end

  defp item(_raw), do: []

  defp package("unit", quantity), do: milli(:unit, quantity, 1)

  defp package(unit, quantity) when is_map_key(@units, unit) do
    {base, factor} = Map.fetch!(@units, unit)
    milli(base, quantity, factor)
  end

  defp package(_unit, _quantity), do: :error

  defp milli(unit, quantity, factor) do
    case round(quantity * factor * 1000) do
      milli when milli > 0 -> {:ok, unit, milli}
      _ -> :error
    end
  end

  defp brand(brand) when is_binary(brand) and brand != "", do: brand
  defp brand(_brand), do: nil
end
