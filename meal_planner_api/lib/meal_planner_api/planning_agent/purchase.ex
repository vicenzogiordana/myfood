defmodule MealPlannerApi.PlanningAgent.Purchase do
  @moduledoc """
  The one deterministic Purchase calculation of the planning agent (spec #93,
  user stories 55–59). It replaces the legacy net-shortage computation for
  the agent flow.

  For a Proposal's meals:

    1. needs are aggregated once per `{ingredient, unit}` across every meal,
       so each purchase is counted once
    2. the Projected Pantry's available stock is subtracted
    3. what remains is rounded up to whole packages of a stored Product in
       the same unit, choosing the lowest package total (ties: lowest
       package price, then name)
    4. each line is priced with its provenance: product, brand,
       presentation, supermarket, currency and observation date

  The consumed-ingredient cost is reported separately: what the meals use
  (Pantry stock included), priced proportionally at the lowest unit price.

  Missing prices are uncertainty, never zero: an ingredient with no stored
  price, no Product in the needed unit, or prices only in another currency
  is listed in `missing` with its reason and left out of the total, which is
  then only a lower bound (`complete?: false`). No unit conversion is applied.

  Stale prices are uncertainty too: every line carries the age of its price,
  and lines priced with an observation 24 hours old or older are listed in
  `stale_prices` (see `MealPlannerApi.PlanningAgent.Prices`).
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Catalog.{Ingredient, RecipeIngredient}
  alias MealPlannerApi.PlanningAgent.{Prices, ProjectedPantry}
  alias MealPlannerApi.Repo

  # Household budgets are stored in cents of this currency.
  @currency "ARS"

  @type key :: {Ecto.UUID.t(), :g | :ml | :unit}
  @type line :: %{
          required(:ingredient_id) => Ecto.UUID.t(),
          required(:quantity_milli) => pos_integer(),
          required(:unit) => :g | :ml | :unit,
          required(:packages) => pos_integer(),
          required(:total_cents) => non_neg_integer(),
          required(:offer) => Prices.offer()
        }
  @type missing :: %{
          ingredient_id: Ecto.UUID.t(),
          ingredient: String.t() | nil,
          quantity_milli: pos_integer(),
          unit: :g | :ml | :unit,
          reason: :no_stored_price | :no_matching_presentation | :currency_mismatch
        }
  @type t :: %{
          lines: [line()],
          missing: [missing()],
          total_cents: non_neg_integer(),
          currency: String.t(),
          complete?: boolean(),
          consumed: %{total_cents: non_neg_integer(), complete?: boolean(), missing: [missing()]}
        }

  @doc "The currency of household budgets and Purchase totals."
  @spec currency() :: String.t()
  def currency, do: @currency

  @doc """
  Calculates the Purchase of `meals` (each with a `recipe_id`) for the
  Household `account_id`, net of its Projected Pantry. A meal whose recipe
  is one of the Recipe Drafts `drafts` (by id) needs the Draft's
  ingredients.

  Options: `:now`, the time prices are aged at (default: the current time).
  """
  @spec for_meals([%{recipe_id: Ecto.UUID.t()}], Ecto.UUID.t(), map(), keyword()) :: t()
  def for_meals(meals, account_id, drafts \\ %{}, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    needs = needs(meals, drafts)
    ingredient_ids = needs |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    available = account_id |> ProjectedPantry.load() |> ProjectedPantry.available()

    calculate(needs, available, Prices.offers_for(ingredient_ids, now), names(ingredient_ids))
  end

  @doc """
  Pure Purchase calculation over aggregated `needs`, `available` stock,
  offers grouped by ingredient id and ingredient names.
  """
  @spec calculate(
          %{key() => pos_integer()},
          %{key() => non_neg_integer()},
          %{Ecto.UUID.t() => [Prices.offer()]},
          %{Ecto.UUID.t() => String.t()}
        ) :: t()
  def calculate(needs, available, offers_by_ingredient, names) do
    sorted = Enum.sort_by(needs, fn {{id, unit}, _} -> {Map.get(names, id), id, unit} end)

    {lines, missing} =
      Enum.reduce(sorted, {[], []}, fn {{id, unit} = key, need}, {lines, missing} ->
        to_buy = need - Map.get(available, key, 0)

        if to_buy <= 0 do
          {lines, missing}
        else
          case usable_offers(offers_by_ingredient, id, unit) do
            {:ok, offers} -> {[line(id, unit, to_buy, offers) | lines], missing}
            {:error, reason} -> {lines, [gap(id, unit, to_buy, reason, names) | missing]}
          end
        end
      end)

    lines = Enum.reverse(lines)
    missing = Enum.reverse(missing)

    %{
      lines: lines,
      missing: missing,
      total_cents: lines |> Enum.map(& &1.total_cents) |> Enum.sum(),
      currency: @currency,
      complete?: missing == [],
      consumed: consumed(sorted, offers_by_ingredient, names)
    }
  end

  @doc "JSON-safe Purchase, as shown to the Member."
  @spec to_data(t()) :: map()
  def to_data(purchase) do
    %{
      "lines" =>
        Enum.map(purchase.lines, fn line ->
          line.offer
          |> Prices.offer_data()
          |> Map.merge(%{
            "quantity_milli" => line.quantity_milli,
            "unit" => Atom.to_string(line.unit),
            "packages" => line.packages,
            "total_cents" => line.total_cents
          })
        end),
      "missing_prices" => Enum.map(purchase.missing, &missing_data/1),
      "stale_prices" =>
        purchase.lines
        |> Enum.reject(& &1.offer.fresh?)
        |> Enum.map(fn line ->
          %{
            "ingredient" => line.offer.ingredient,
            "product" => line.offer.product,
            "observed_at" => DateTime.to_iso8601(line.offer.observed_at),
            "age_hours" => div(line.offer.age_seconds, 3600)
          }
        end),
      "total_cents" => purchase.total_cents,
      "currency" => purchase.currency,
      "complete" => purchase.complete?
    }
  end

  @doc "Whether any line of the Purchase is priced with a stale observation."
  @spec stale?(t()) :: boolean()
  def stale?(purchase), do: Enum.any?(purchase.lines, &(not &1.offer.fresh?))

  @doc "JSON-safe consumed-ingredient cost."
  @spec consumed_data(t()) :: map()
  def consumed_data(purchase) do
    %{
      "total_cents" => purchase.consumed.total_cents,
      "currency" => purchase.currency,
      "complete" => purchase.consumed.complete?,
      "missing_prices" => Enum.map(purchase.consumed.missing, &missing_data/1)
    }
  end

  # ---------------------------------------------------------------------------

  defp line(id, unit, to_buy, offers) do
    {offer, packages, total} =
      offers
      |> Enum.map(fn offer ->
        packages = ceil_div(to_buy, offer.package_quantity_milli)
        {offer, packages, packages * offer.price_cents}
      end)
      |> Enum.min_by(fn {offer, _packages, total} ->
        {total, offer.price_cents, offer.product, offer.product_id}
      end)

    %{
      ingredient_id: id,
      quantity_milli: to_buy,
      unit: unit,
      packages: packages,
      total_cents: total,
      offer: offer
    }
  end

  defp consumed(sorted_needs, offers_by_ingredient, names) do
    {total, missing} =
      Enum.reduce(sorted_needs, {0, []}, fn {{id, unit}, need}, {total, missing} ->
        case usable_offers(offers_by_ingredient, id, unit) do
          {:ok, offers} ->
            cost =
              offers
              |> Enum.map(&proportional_cost(need, &1))
              |> Enum.min()

            {total + cost, missing}

          {:error, reason} ->
            {total, [gap(id, unit, need, reason, names) | missing]}
        end
      end)

    %{total_cents: total, complete?: missing == [], missing: Enum.reverse(missing)}
  end

  # Rounded half up, in integer arithmetic.
  defp proportional_cost(quantity, offer) do
    div(
      2 * quantity * offer.price_cents + offer.package_quantity_milli,
      2 * offer.package_quantity_milli
    )
  end

  defp usable_offers(offers_by_ingredient, id, unit) do
    offers = Map.get(offers_by_ingredient, id, [])
    same_unit = Enum.filter(offers, &(&1.package_unit == unit))

    cond do
      offers == [] -> {:error, :no_stored_price}
      same_unit == [] -> {:error, :no_matching_presentation}
      true -> currency_offers(same_unit)
    end
  end

  defp currency_offers(offers) do
    case Enum.filter(offers, &(&1.currency == @currency)) do
      [] -> {:error, :currency_mismatch}
      usable -> {:ok, usable}
    end
  end

  defp gap(id, unit, quantity, reason, names) do
    %{
      ingredient_id: id,
      ingredient: Map.get(names, id),
      quantity_milli: quantity,
      unit: unit,
      reason: reason
    }
  end

  defp missing_data(missing) do
    %{
      "ingredient" => missing.ingredient,
      "quantity_milli" => missing.quantity_milli,
      "unit" => Atom.to_string(missing.unit),
      "reason" => Atom.to_string(missing.reason)
    }
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp needs(meals, drafts) do
    counts = Enum.frequencies_by(meals, & &1.recipe_id)
    {draft_ids, stored_ids} = counts |> Map.keys() |> Enum.split_with(&Map.has_key?(drafts, &1))
    ids = Enum.flat_map(stored_ids, &cast_uuid/1)

    draft_rows =
      for id <- draft_ids,
          item <- Map.fetch!(drafts, id).ingredients,
          do: {id, item.ingredient_id, item.unit, item.quantity_milli}

    from(ri in RecipeIngredient,
      where: ri.recipe_id in ^ids,
      select: {ri.recipe_id, ri.ingredient_id, ri.unit, ri.quantity_milli}
    )
    |> Repo.all()
    |> Kernel.++(draft_rows)
    |> Enum.reduce(%{}, fn {recipe_id, ingredient_id, unit, quantity}, acc ->
      total = quantity * Map.fetch!(counts, recipe_id)
      Map.update(acc, {ingredient_id, unit}, total, &(&1 + total))
    end)
  end

  defp names([]), do: %{}

  defp names(ids) do
    from(i in Ingredient, where: i.id in ^ids, select: {i.id, i.name})
    |> Repo.all()
    |> Map.new()
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> [uuid]
      :error -> []
    end
  end
end
