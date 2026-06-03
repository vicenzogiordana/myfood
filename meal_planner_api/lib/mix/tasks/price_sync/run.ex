defmodule Mix.Tasks.PriceSync.Run do
  @moduledoc """
  Fetches current ingredient prices from the Go scraper API and updates the database.

  Run nightly via cron/scheduler (e.g. every 12h). You can also run it manually:

      mix price_sync.run

  ## What it does

  1. Lists all ingredients in the database
  2. For each ingredient (with retry on failure):
       a. Calls `GET /?q=<ingredient_name>` on the Go scraper API
       b. For each product returned:
            - Looks up the `UnitConversion` factor for `(ingredient_id, from_unit)`
            - Skips if no conversion found (unrecognized unit for this ingredient)
            - Skips if `unavailable: true`
          c. Stores price in `ingredient_prices` via `PriceRepo.upsert_prices/1`
  3. Calls `PriceRepo.compute_all_recipe_prices/0` to update all recipe prices
  4. Logs a summary: N prices updated, M recipes computed, K failed (per ingredient)

  ## Environment variables

      GO_SCRAPER_URL   Base URL of the Go scraper API (default: http://localhost:3000)

  ## Exit codes

      0 — Success
      1 — All ingredients failed (Go API unreachable or all retries exhausted)
      2 — Partial failure (some ingredients succeeded, some failed)
  """

  use Mix.Task

  alias MealPlannerApi.Data.{PriceRepo, UnitConversionRepo}
  alias MealPlannerApi.Integrations.GoScraperClient

  @max_retries 1
  @log_every 10

  @impl true
  def run(_args) do
    Mix.shell().info("Starting price sync...")

    # Use real client in dev/prod, mock can be injected via Application env
    client = Application.get_env(:meal_planner_api, :go_scraper_client, GoScraperClient)

    ingredients = list_all_ingredients()
    total = length(ingredients)

    Mix.shell().info("Found #{total} ingredients to sync.")

    results =
      ingredients
      |> Enum.with_index(1)
      |> Enum.map(fn {ingredient, idx} ->
        if rem(idx, @log_every) == 0 do
          Mix.shell().info("[#{idx}/#{total}] Syncing: #{ingredient.name}")
        end

        sync_ingredient(ingredient, client)
      end)

    # Aggregate
    {ok_count, skipped_unit, error_count} =
      results
      |> Enum.reduce({0, 0, 0}, fn
        {:ok, _}, {ok, s, e} -> {ok + 1, s, e}
        {:skipped, _}, {ok, s, e} -> {ok, s + 1, e}
        {:error, _}, {ok, s, e} -> {ok, s, e + 1}
      end)

    # Update recipe prices
    {recipes_computed, recipes_skipped} = PriceRepo.compute_all_recipe_prices()

    Mix.shell().info("""
    ── Price Sync Summary ─────────────────────────
    Ingredients: #{ok_count} synced, #{skipped_unit} skipped (no unit conversion), #{error_count} failed
    Recipes:    #{recipes_computed} computed, #{recipes_skipped} skipped (missing price for ingredient)
    ───────────────────────────────────────────────
    """)

    exit_code =
      cond do
        ok_count == 0 -> 1
        error_count > 0 -> 2
        true -> 0
      end

    {:ok, exit_code}
  end

  # -------------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------------

  defp sync_ingredient(ingredient, client) do
    with {:ok, result} <- fetch_with_retry(ingredient.name, client, @max_retries),
         %{products: products, failed_scrapers: _failed} <- result,
         true <- products != [] do
      price_rows = build_price_rows(ingredient.id, products)

      case price_rows do
        [] ->
          {:skipped, :no_valid_unit_conversion}

        rows ->
          {count, _} = PriceRepo.upsert_prices(rows)
          {:ok, count}
      end
    else
      {:error, reason} ->
        Mix.shell().error("  ✗ Failed to fetch '#{ingredient.name}': #{inspect(reason)}")
        {:error, reason}

      %{} ->
        {:skipped, :no_products}

      false ->
        {:skipped, :empty_products}
    end
  end

  defp fetch_with_retry(ingredient_name, client, retries) do
    fetch_once = fn ->
      case client.fetch(ingredient_name) do
        {:ok, _} = result ->
          result

        {:error, reason} when reason in [:timeout, :unreachable] ->
          {:retry, reason}

        {:error, _} = error ->
          error
      end
    end

    try do
      case fetch_once.() do
        {:retry, reason} when retries > 0 ->
          Mix.shell().warn(
            "  Retry #{@max_retries - retries + 1} for '#{ingredient_name}' (#{reason})"
          )

          fetch_with_retry(ingredient_name, client, retries - 1)

        other ->
          other
      end
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp build_price_rows(ingredient_id, products) do
    now = DateTime.utc_now()

    products
    |> Enum.reject(fn p -> p.unavailable end)
    |> Enum.map(fn p ->
      conversion = UnitConversionRepo.get_conversion_factor(ingredient_id, p.unit)

      if conversion do
        cents =
          p.unit_price
          |> Kernel.*(conversion)
          |> GoScraperClient.unit_price_to_cents()

        {:ok,
         %{
           ingredient_id: ingredient_id,
           supermarket_id: p.source,
           price_per_unit_cents: cents,
           unit: p.unit,
           scraped_at: now
         }}
      else
        {:skip, p.unit}
      end
    end)
    |> Enum.reject(fn
      {:skip, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:ok, row} -> row end)
  end

  defp list_all_ingredients do
    MealPlannerApi.Persistence.Catalog.list_ingredients()
  end
end
