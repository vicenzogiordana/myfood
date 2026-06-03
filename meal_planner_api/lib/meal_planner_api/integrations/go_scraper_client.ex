defmodule MealPlannerApi.Integrations.GoScraperClient do
  @moduledoc """
  HTTP client for the Go scraper API (Ratoneando).

  Fetches normalized product prices for a given ingredient query.
  Used only by the nightly `mix price_sync.run` task.

  ## Go API response shape

      %{
        "products" => [
          %{
            "source"      => "jumbo",
            "name"       => "Pollo entero 1kg",
            "price"      => 1500.0,
            "unitPrice"  => 15.0,   # price per base unit (kg/l/unit)
            "unit"       => "kg",
            "unavailable" => false
          },
          ...
        ],
        "failedScrapers" => ["carrefour"]
      }

  ## Price normalization strategy

  We use `unitPrice` (not raw `price`) because it is already normalized
  per kg/l/unit — package size does not affect it. This means a 500g pack
  and a 1kg pack of the same product get the same unitPrice.

  To store in DB (cents, base unit), we do:

      price_per_unit_cents = round(unitPrice × 100)

  The `unit` field from the API tells us what the unitPrice is expressed in.
  It must match one of our `UnitConversion.from_unit` entries for that ingredient,
  otherwise we skip that product.
  """

  @base_url Application.compile_env(:meal_planner_api, :go_scraper_url, "http://localhost:3000")
  @timeout 15_000

  @typedoc "A single product result from the Go scraper API."
  @type scraped_product :: %{
          source: String.t(),
          name: String.t(),
          price: float(),
          unit_price: float(),
          unit: String.t(),
          unavailable: boolean()
        }

  @typedoc "Full parsed API response."
  @type scrape_result :: %{
          products: [scraped_product()],
          failed_scrapers: [String.t()]
        }

  # -------------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------------

  @doc """
  Fetches product prices for a single ingredient from the Go scraper API.

  Returns `{:ok, result}` or `{:error, :unreachable | :timeout | :parse_error}`.

  Calls `GET #{@base_url}/?q=<ingredient_name>` (query must be lowercase).
  """
  @spec fetch(String.t()) ::
          {:ok, scrape_result()} | {:error, :unreachable | :timeout | :parse_error}
  def fetch(ingredient_name) when is_binary(ingredient_name) do
    query = String.downcase(ingredient_name)
    url = "#{@base_url}/?q=#{URI.encode_www_form(query)}"

    case Tesla.get(url, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: body}} ->
        parse_response(body)

      {:ok, %{status: status}} when status >= 400 ->
        {:error, :unreachable}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :unreachable}
    end
  end

  @doc """
  Converts a `unitPrice` (float, price per base unit) to cents for storage.

      iex> GoScraperClient.unit_price_to_cents(15.99)
      1599
  """
  @spec unit_price_to_cents(float()) :: non_neg_integer()
  def unit_price_to_cents(unit_price) when is_float(unit_price) do
    round(unit_price * 100)
  end

  @doc "The configured Go scraper base URL."
  @spec base_url() :: String.t()
  def base_url, do: @base_url

  # -------------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------------

  defp parse_response(body) when is_map(body) do
    products =
      Enum.map(body["products"] || [], fn p ->
        %{
          source: p["source"] || "",
          name: p["name"] || "",
          price: p["price"] || 0.0,
          unit_price: p["unitPrice"] || 0.0,
          unit: p["unit"] || "",
          unavailable: p["unavailable"] || false
        }
      end)

    failed_scrapers = body["failedScrapers"] || []

    {:ok, %{products: products, failed_scrapers: failed_scrapers}}
  rescue
    _ -> {:error, :parse_error}
  end

  defp parse_response(_), do: {:error, :parse_error}
end
